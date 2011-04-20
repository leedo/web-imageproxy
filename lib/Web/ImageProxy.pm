package Web::ImageProxy;

use strict;
use warnings;

use CHI;
use Path::Class qw/dir file/;
use URI::Escape;
use AnyEvent::HTTP;
use HTTP::Date;
use List::Util qw/shuffle/;
use List::MoreUtils qw/any/;
use Digest::SHA1 qw/sha1_hex/;

use Plack::Util;
use Plack::Util::Accessor qw/cache cache_root max_size allowed_referers/;

use parent 'Plack::Component';

our $REQ_HEADERS = {
  "User-Agent" => "Mozilla/5.0 (Macintosh; U; Intel Mac OS X; en) AppleWebKit/419.3 (KHTML, like Gecko) Safari/419.3",
  "Referer" => undef,
};

sub prepare_app {
  my $self = shift;

  $self->{max_size} = 2097152 * 2     unless defined $self->{max_size};
  $self->{allowed_referers} = []      unless defined $self->{allowed_referers};

  unless (defined $self->{cache}) {
    $self->{cache_root} = "./cache"   unless defined $self->{cache_root};
    $self->{cache} = $self->build_cache;
  }

  $self->{locks} = {};
}

sub build_cache {
  my $self = shift;

  my $r = dir($self->cache_root);
  $r->mkpath unless -e $r;

  return CHI->new(
    driver => "File",
    root_dir => "$r",
    expires_in => 2419200, # one month
  );
}

sub call {
  my ($self, $env) = @_;

  return $self->not_found      if $env->{PATH_INFO} =~ /^\/?favicon.ico/;

  my $url = build_url($env);

  return $self->not_found      unless $url;
  return $self->redirect($url) unless $self->valid_referer($env);

  return $self->handle_url($url, $env);
}

sub asset_res {
  my ($self, $name) = @_;
  my $file = file("static/image/$name.gif");
  my $fh = $file->openr;
  Plack::Util::set_io_path($fh);

  if ($file) {
    return [
      200,
      ["Content-Type", "image/gif", "Content-Length", $file->stat->size],
      $fh,
    ];
  }
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

sub valid_referer {
  my ($self, $env) = @_;
  my $referer = $env->{HTTP_REFERER};
  return 1 unless $referer or !@{$self->allowed_referers};
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

sub handle_url {
  my ($self, $url, $env) = @_;

  if ($self->has_lock($url)) { # downloading
    return sub {
      my $cb = shift;
      $self->add_lock_callback($url, $cb);
    };
  }

  my $file = file($self->cache->path_to_key($url));
  my $meta = $self->cache->get("$url-meta");
  my $uncache = $url =~ /(gravatar\.com|\?.*uncache=1)/;

  if (!$uncache and $meta) { # info cached
    my $resp;

    if (my $error = $meta->{error}) {
      return $self->$error;
    }

    elsif ($meta->{headers} and -e $file->absolute->stringify) {
      
      if ($self->is_unchanged($meta, $env)) {
        return [304, ['ETag' => $meta->{etag}, 'Last-Modified' => $meta->{modified}], []];
      }

      my $fh = $file->openr;
      Plack::Util::set_io_path($fh);
      
      return [200, $meta->{headers}, $fh];
    }
  }

  return sub { # new download
    my $cb = shift;
    $self->add_lock_callback($url, $cb); 
    $self->download($url);
  };

}

sub download {
  my ($self, $url) = @_;

  my $cache = file($self->cache->path_to_key($url));
  $cache->parent->mkpath;
  my $fh = $cache->openw;

  my $length = 0;
  my $is_image = 0;
  my $image_header;

  http_get $url,
    headers => $REQ_HEADERS,
    on_header => sub {$self->check_headers(@_, $url)},
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
            $self->lock_respond($url, $self->asset_res("badformat"));
            $cache->remove;
            return 0;
          }
        }
        return 1;
      }

      if ($length > $self->max_size) {
        $self->lock_respond($url, $self->asset_res("toolarge"));
        $cache->remove;
        return 0;
      }

      print $fh $data;
      return 1
    },

    sub {
      my (undef, $headers) = @_;

      if ($headers->{Status} != 200) {
        print STDERR "got $headers->{Status} for $url: $headers->{Reason}\n";
        $self->lock_respond($url, $self->asset_res("cannotread"));
        return;
      }

      # the file is under 1K so nothing has been written
      if (!$is_image) {
        if (my $mime = $self->get_mime_type($image_header)) {
          $headers->{'content-type'} = $mime;
          print $fh $image_header;
        }
        else {
          $self->lock_respond($url, $self->asset_res("badformat"));
          $cache->remove;
          return;
        }
      }

      $fh = file($self->cache->path_to_key($url))->openr;

      my $modified = $headers->{last_modified} || time2str(time);
      my $etag = $headers->{etag} || sha1_hex($url);

      my @headers = (
        "Content-Type" => $headers->{'content-type'},
        "Content-Length" => $length,
        "Cache-Control" => "public, max-age=86400",
        "Last-Modified" => $modified,
        "ETag" => $etag,
      );

      $self->cache->set("$url-meta", {
        headers => \@headers,
        etag => $etag,
        modified => $modified,
      });

      Plack::Util::set_io_path($fh);
      $self->lock_respond($url,[200, \@headers, $fh]);
    }
}

sub check_headers {
  my ($self, $headers, $url) = @_;
  my ($length, $type) = @$headers{'content-length', 'content-type'};

  if ($headers->{Status} != 200) {
    print STDERR "got $headers->{Status} for $url: $headers->{Reason}\n";
    $self->lock_respond($url, $self->asset_res("cannotread"));
    return 0;
  }

  if ($length and $length > $self->max_size) {
    $self->lock_respond($url, $self->asset_res("toolarge"));
    $self->cache->set("$url-meta", {error => "toolarge"});
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


sub build_url {
  my $env = shift;
  my $url = substr($env->{REQUEST_URI}, length($env->{SCRIPT_NAME}));
  $url =~ s{^/+}{};
  $url =~ s/&amp;/&/g;
  return if !$url or $url eq "/";
  $url =~ s{^(https?:/)([^/])}{$1/$2}i;
  $url = "http://$url" unless $url =~ /^https?/i;
  $url =~ s/\s/%20/g;
  return $url;
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
