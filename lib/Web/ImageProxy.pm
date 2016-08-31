package Web::ImageProxy;

use strict;
use warnings;

use AnyEvent::Fork;
use AnyEvent::Fork::Pool;
use AnyEvent::HTTP;
use HTTP::Date;
use URI::Escape;
use Plack::Util;

use File::Temp qw(tempfile tempdir);
use JSON::XS;

use List::MoreUtils qw/any/;
use Digest::SHA1 qw/sha1_hex/;

use Plack::Util;
use Plack::Util::Accessor qw/max_size allowed_referers/;

use parent 'Plack::Component';

my $dir = tempdir();
our $REQ_HEADERS = {
  "User-Agent" => "Mozilla/5.0 (Macintosh; U; Intel Mac OS X; en) AppleWebKit/419.3 (KHTML, like Gecko) Safari/419.3",
  "Referer" => undef,
};

sub prepare_app {
  my $self = shift;

  $self->{max_size} = 10485760      unless defined $self->{max_size};
  $self->{allowed_referers} = []    unless defined $self->{allowed_referers};

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

sub handle_url {
  my ($self, $url, $env, %options) = @_;
  return sub {
    my $cb = shift;
    $self->download($url, $cb, %options);
  };

}

sub download {
  my ($self, $url, $cb, %options) = @_;

  my $length = 0;
  my $is_image = 0;
  my $image_header;
  my ($fh, $file);

  http_get $url,
    headers => $REQ_HEADERS,
    on_header => sub {$self->check_headers(@_, $cb)},
    timeout => 60,
    on_body => sub {
      my ($data, $headers) = @_;

      if ($headers->{Status} != 200) {
        return 1;
      }

      $length += length $data;

      if (!$is_image) {
        $image_header .= $data;

        if ($length > 1024) {
          if (my $mime = $self->get_mime_type($image_header)) {
            $is_image = 1;
            $headers->{'content-type'} = $mime;
            ($fh, $file) = tempfile( DIR => $dir );
            print $fh $image_header;
            $image_header = '';
          }
          else {
            $cb->($self->not_found);
            return 0;
          }
        }
        return 1;
      }

      if ($length > $self->max_size) {
        $cb->($self->not_found);
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
        return $cb->($self->not_found);
      }

      # the file is under 1K so nothing has been written
      if (!$is_image) {
        if (my $mime = $self->get_mime_type($image_header)) {
          $headers->{'content-type'} = $mime;
          ($fh, $file) = tempfile( DIR => $dir );
          print $fh $image_header;
        }
        else {
          unlink $file;
          return $cb->($self->not_found);
        }
      }

      close $fh;

      my $modified = $headers->{last_modified} || time2str(time);
      my $etag = $headers->{etag} || sha1_hex($url);

      my $res_headers = [
        "Content-Type" => $headers->{'content-type'},
        "Content-Length" => $length,
        "Last-Modified" => $modified,
        "ETag" => $etag,
      ];

      if (!%options) {
        open my $fh, "<", $file;
        $cb->([200, $res_headers, $fh]);
        unlink $file;
        return;
      }

      $self->{resizer}->($file, %options, sub {
        warn $@ if $@;

        my $resized_length = (stat($file))[7];
        Plack::Util::header_set($res_headers, "Content-Length", $resized_length);
        Plack::Util::header_push($res_headers, "X-Image-Original-Length", $length);

        open my $fh, "<", $file;
        $cb->([200, $res_headers, $fh]);
        unlink $file;
      });
    };
}

sub check_headers {
  my ($self, $headers, $cb) = @_;
  my ($length, $type) = @$headers{'content-length', 'content-type'};

  if ($headers->{Status} != 200) {
    return 0;
  }

  if ($length and $length =~ /^\d+$/ and $length > $self->max_size) {
    $cb->($self->not_found);
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

1;
