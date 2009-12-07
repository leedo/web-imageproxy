package Plack::App::ImageProxy;

use strict;
use warnings;

use parent 'Plack::Middleware';
use Path::Class qw/dir/;
use Cache::File;
use AnyEvent::HTTP;
use Image::Magick;
use Storable qw/freeze thaw/;

__PACKAGE__->mk_ro_accessors(qw/cache locks/);
__PACKAGE__->mk_accessors(qw/cache_root max_size req_headers/);

my $default_headers = {
      "User-Agent" => "Mozilla/5.0 (Macintosh; U; Intel Mac OS X; en) AppleWebKit/419.3 (KHTML, like Gecko) Safari/419.3",
};

sub new {
  my ($class, %args) = @_;
  $args{locks} = {};
  $args{req_headers} = $default_headers;
  $args{max_size} = 2097152;
  $args{cache} = Cache::File->new(
    cache_root => $args{cache_root} || './cache/images/');
  $class->SUPER::new(%args);
}

sub call {
  my ($self, $env) = @_;
  my $url = $env->{'PATH_INFO'} || '';
  $url =~ s/^\/+//;
  if ($self->has_lock($url)) { # downloading
    return sub {
      my $cb = shift;
      $self->add_lock_callback($url, $cb);
    };
  }
  elsif (my $data = $self->cache->get($url)) {
    my ($mime, $body) = @{ thaw $data };
    return [200,["Content-Type", $mime],[$body]];
  }
  else { # new download
    return sub {
      my $cb = shift;
      $self->add_lock_callback($url, $cb); 
      $self->download($url);
    };
  }
}

sub download {
  my ($self, $url) = @_;
  if ($url and $url =~ /^http:\/\//) {
    my $body;
    http_get $url,
      headers => $self->req_headers,
      on_header => sub {$self->check_headers(@_, $url)},
      on_body => sub {
        my ($partial, $headers) = @_;
        $body .= $partial;
        if (length($body) > $self->max_size) {
          $self->error("too large", $url);
          return 0;
        }
        return 1;
      },
      sub {$self->complete($body, $_[1], $url)};
  }
  else {
    $self->error("invalid url: $url", $url);
  }
}

sub complete {
  my ($self, $body, $headers, $url) = @_;
  return if $headers->{Status} == 598;
  if (!$body) {
    $self->error("empty response body", $url);
  }
  elsif (length($body) > $self->max_size) {
    $self->error("too large", $url);
  }
  else {
    if (my $mime = $self->get_mime($body, $url)) {
      $self->lock_respond($url, sub {
        [200, ["Content-Type", $mime], [$body]];
      });
      $self->cache->set($url, freeze [$mime, $body]);
    }
  }
}

sub get_mime {
  my ($self, $blob, $url) = @_;
  my $image = Image::Magick->new;
  $image->BlobToImage($blob);
  my $mime = $image->Get('mime');
  if ($mime !~ /^image/) {
    $self->error("not an image", $url);
    return undef;
  }
  return $mime;
}

sub check_headers {
  my ($self, $headers, $url) = @_;
  if ($headers->{Status} != 200) {
    $self->error("got $headers->{Status}", $url);
    return 0;
  }
  if ($headers->{'content-length'} and $headers->{'content-length'} > $self->max_size) {
    $self->error("too large", $url);
    return 0;
  }
  elsif ($headers->{'content-type'} and $headers->{'content-type'} !~ /^image/) {
    $self->error("invalid content type", $url);
    return 0;
  }
  return 1;
}

sub error {
  my ($self, $error, $url) = @_;
  $error = "error: $error";
  $self->lock_respond($url, sub {
    [404, ["Content-Type", "text/plain"], [$error]];
  });
}

sub lock_respond {
  my ($self, $url, $cb) = @_;
  if ($self->has_lock($url)) {
    for my $lock_cb ($self->get_lock_callbacks($url)) {
      $lock_cb->( $cb->());
    }
    $self->remove_lock($url);
  }
}

sub has_lock {
  my ($self, $url) = @_;
  exists $self->locks->{$url};
}

sub get_lock_callbacks {
  my ($self, $url) = @_;
  @{$self->locks->{$url}};
}

sub add_lock_callback {
  my ($self, $url, $cb) = @_;
  if ($self->has_lock($url)) {
    push @{$self->locks->{$url}}, $cb;
  }
  else {
    $self->locks->{$url} = [$cb];
  }
}

sub remove_lock {
  my ($self, $url) = @_;
  delete $self->locks->{$url};
}

1;
