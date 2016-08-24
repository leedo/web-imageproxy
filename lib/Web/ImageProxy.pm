package Web::ImageProxy;

use strict;
use warnings;

use AnyEvent::Fork;
use AnyEvent::Fork::Pool;
use AnyEvent::HTTP;
use HTTP::Date;
use URI::Escape;
use Plack::Util;

use File::Spec;
use File::Path qw/make_path/;
use List::Util qw/shuffle/;
use JSON::XS;

use List::MoreUtils qw/any/;
use Digest::SHA1 qw/sha1_hex/;

use Plack::Util;
use Plack::Util::Accessor qw/cache_root max_size allowed_referers/;

use parent 'Plack::Component';

our $REQ_HEADERS = {
  "User-Agent" => "Mozilla/5.0 (Macintosh; U; Intel Mac OS X; en) AppleWebKit/419.3 (KHTML, like Gecko) Safari/419.3",
  "Referer" => undef,
};

sub prepare_app {
  my $self = shift;

  $self->{max_size} = 10485760      unless defined $self->{max_size};
  $self->{allowed_referers} = []    unless defined $self->{allowed_referers};

  $self->{static_dir} = "./static"  unless defined $self->{static_dir};
  $self->{cache_root} = "./cache"   unless defined $self->{cache_root};
  make_path $self->{cache_root}     unless -e $self->{cache_root};

  $self->{locks} = {};
  $self->{resizer} = AnyEvent::Fork
    ->new
    ->require('Web::ImageProxy::Resizer')
    ->AnyEvent::Fork::Pool::run(
      "Web::ImageProxy::Resizer::resize",
    );
}

sub call {
  my ($self, $env) = @_;

  return $self->not_found if $env->{PATH_INFO} =~ /^\/?favicon.ico/;

  my %options;
  my $path = substr($env->{REQUEST_URI}, length($env->{SCRIPT_NAME}));
  my @parts = grep {length $_} split "/", $path;

  if (@parts and $parts[0] eq "still") {
    $options{still} = shift @parts;
  }

  if (@parts and $parts[0] =~ /^[0-9]+$/) {
    $options{width} = shift @parts;
  }

  if (@parts and $parts[0] =~ /^[0-9]+$/) {
    $options{height} = shift @parts;
  }

  if (defined $options{height} and $options{height} == 0 and
       defined $options{width} and $options{width} == 0) {
    delete $options{height};
    delete $options{width};
  }

  my $url = clean_url(join "/", @parts);

  return $self->not_found      unless $url;
  return $self->redirect($url) unless $self->valid_referer($env);

  return $self->handle_url($url, $env, %options);
}

sub not_found {
  my $self = shift;
  return [
    404,
    ['Content-Type', 'text/plain'],
    ['not found']
  ];
}

sub redirect {
  my ($self, $url) = @_;
  return [
    301,
    [Location => $url],
    ['go away'],
  ];
}

sub error {
  my $self = shift;
  return [
    500,
    ['Content-Type', 'text/plain'],
    ['error processing request']
  ];
}

sub valid_referer {
  my ($self, $env) = @_;
  my $referer = $env->{HTTP_REFERER};
  return 1 unless $referer and @{$self->allowed_referers};
  return any {$referer =~ $_} @{$self->allowed_referers};
}

sub is_unchanged {
  my ($self, $meta, $env) = @_;

  my $modified = $env->{"HTTP_IF_MODIFIED_SINCE"};
  my $etag = $env->{"IF_NONE_MATCH"};

  if ($modified) {
    return $modified eq $meta->{modified}
  }
  elsif ($etag) {
    return $etag eq $meta->{etag};
  }

  return 0;
}

sub key_to_path {
  my ($self, $url) = @_;

  # hash url to get 2 characters for dirs
  my $hash = sha1_hex($url);

  my $dir = File::Spec->catdir($self->{cache_root}, split("", substr($hash, 0, 2)));
  my $file = File::Spec->catfile($dir, $hash);

  wantarray ? ($dir, $file) : $file;
}

sub save_meta {
  my ($self, $key, $data) = @_;

  my ($dir, $file) = $self->key_to_path("$key-meta");
  make_path $dir if !-e $dir;

  open my $fh, ">", $file or $self->lock_error($key, $!);
  print $fh encode_json($data);
}

sub get_meta {
  my ($self, $key) = @_;

  my $file = $self->key_to_path("$key-meta");

  if (-e $file) {
    open my $fh, "<", $file or $self->lock_error($key, $!);
    local $/;
    my $data = <$fh>;
    decode_json($data);
  }
}

sub handle_url {
  my ($self, $url, $env, %options) = @_;

  my $key = join "-", $url, %options;

  if ($self->has_lock($key)) { # downloading
    return sub {
      my $cb = shift;
      $self->add_lock_callback($key, $cb);
    };
  }

  my $meta = $self->get_meta($key);

  if ($meta) { # info cached
    if ($self->is_unchanged($meta, $env)) {
      return [
        304,
        [
          'ETag' => $meta->{etag},
          'Last-Modified' => $meta->{modified},
          'X-Cache-Hit' => "true",
        ],
        []
      ];
    }

    my $file = $self->key_to_path($key);
    if ($meta->{headers} and -e $file) {
      open my $fh, "<", $file or $self->lock_error($key, $!);
      push @{ $meta->{headers} }, "X-Cache-Hit", "true";
      return [200, $meta->{headers}, $fh];
    }
  }

  return sub { # new download
    my $cb = shift;
    $self->add_lock_callback($key, $cb); 
    $self->download($url, $key, %options);
  };

}

sub download {
  my ($self, $url, $key, %options) = @_;

  my ($dir, $file) = $self->key_to_path($key);
  make_path $dir unless -e $dir;
  open my $fh, ">", $file or $self->lock_error($key, $!);

  my $length = 0;
  my $is_image = 0;
  my $image_header;

  http_get $url,
    headers => $REQ_HEADERS,
    on_header => sub {$self->check_headers(@_, $key)},
    timeout => 60,
    on_body => sub {
      my ($data, $headers) = @_;

      return 1 unless $headers->{Status} == 200;

      $length += length $data;

      if (!$is_image) {
        $image_header .= $data;

        if ($length > 1024) {
          if (my $mime = $self->get_mime_type($image_header)) {
            $is_image = 1;
            $headers->{'content-type'} = $mime;
            print $fh $image_header;
            $image_header = '';
          }
          else {
            $self->lock_respond($key, $self->not_found);
            unlink $file;
            return 0;
          }
        }
        return 1;
      }

      if ($length > $self->max_size) {
        $self->lock_respond($key, $self->not_found);
        unlink $file;
        return 0;
      }

      print $fh $data;
      return 1
    },

    sub {
      my (undef, $headers) = @_;

      if ($headers->{Status} != 200) {
        print STDERR "got $headers->{Status} for $url: $headers->{Reason}\n";
        $self->lock_respond($key, $self->not_found);
        return;
      }

      # the file is under 1K so nothing has been written
      if (!$is_image) {
        if (my $mime = $self->get_mime_type($image_header)) {
          $headers->{'content-type'} = $mime;
          print $fh $image_header;
        }
        else {
          $self->lock_respond($key, $self->not_found);
          unlink $file;
          return;
        }
      }

      close $fh;

      my $modified = $headers->{last_modified} || time2str(time);
      my $etag = $headers->{etag} || sha1_hex($url);

      my $res_headers = [
        "Content-Type" => $headers->{'content-type'},
        "Content-Length" => $length,
        "Cache-Control" => "public, max-age=86400",
        "Last-Modified" => $modified,
        "ETag" => $etag,
      ];

      $self->save_meta($key, {
        headers => $res_headers,
        etag => $etag,
        modified => $modified,
      });

      if (!%options) {
        open $fh, "<", $file;
        $self->lock_respond($key, [200, $res_headers, $fh]);
        return;
      }

      $self->{resizer}->($file, %options, sub {
        warn $@ if $@;

        my $resized_length = (stat($file))[7];
        Plack::Util::header_set($res_headers, "Content-Length", $resized_length);
        Plack::Util::header_push($res_headers, "X-Image-Original-Length", $length);

        open $fh, "<", $file;
        $self->lock_respond($key,[200, $res_headers, $fh]);
      });
    };
}

sub check_headers {
  my ($self, $headers, $key) = @_;
  my ($length, $type) = @$headers{'content-length', 'content-type'};

  if ($headers->{Status} != 200) {
    print STDERR "got $headers->{Status} for $key: $headers->{Reason}\n";
    $self->lock_respond($key, $self->not_found);
    return 0;
  }

  if ($length and $length =~ /^\d+$/ and $length > $self->max_size) {
    $self->lock_respond($key, $self->not_found);
    return 0;
  }

  return 1;
}

# taken from File::Type::WebImages
sub get_mime_type {
  my ($self, $data) = @_;
  my $substr;

  return undef unless defined $data;

  if ($data =~ m[^\x89PNG]) {
    return q{image/png};
  } 
  elsif ($data =~ m[^GIF8]) {
    return q{image/gif};
  }
  elsif ($data =~ m[^BM]) {
    return q{image/bmp};
  }

  if (length $data > 1) {
    $substr = substr($data, 1, 1024);
    if (defined $substr && $substr =~ m[^PNG]) {
      return q{image/png};
    }
  }
  if (length $data > 0) {
    $substr = substr($data, 0, 2);
    if (pack('H*', 'ffd8') eq $substr ) {
      return q{image/jpeg};
    }
  }

  return undef;
}

sub clean_url {
  my $path = shift;
  $path =~ s{^/+}{};

  return if !$path or $path eq "/";

  $path =~ s/&amp;/&/g;
  $path =~ s/\s/%20/g;
  $path =~ s{^(https?:/)([^/])}{$1/$2}i;
  $path = "http://$path" unless $path =~ /^https?/i;

  return $path;
}

sub lock_error {
  my ($self, $key, $message) = @_;
  $self->lock_respond($key, $self->error);
  warn "error: $message";
  die;
}

sub lock_respond {
  my ($self, $url, $res) = @_;
  if ($self->has_lock($url)) {
    for my $lock_cb ($self->get_lock_callbacks($url)) {
      $lock_cb->($res);
    }
    $self->remove_lock($url);
  }
}

sub has_lock {
  my ($self, $url) = @_;
  exists $self->{locks}->{$url};
}

sub get_lock_callbacks {
  my ($self, $url) = @_;
  @{$self->{locks}->{$url}};
}

sub add_lock_callback {
  my ($self, $url, $cb) = @_;
  if ($self->has_lock($url)) {
    push @{$self->{locks}->{$url}}, $cb;
  }
  else {
    $self->{locks}->{$url} = [$cb];
  }
}

sub remove_lock {
  my ($self, $url) = @_;
  delete $self->{locks}->{$url};
}

1;
