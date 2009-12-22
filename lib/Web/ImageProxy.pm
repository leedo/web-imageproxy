package Web::ImageProxy;

use strict;
use warnings;

use Path::Class qw/dir/;
use Cache::File;
use URI::Escape;
use AnyEvent::HTTP;
use Image::Magick;
use Storable qw/freeze thaw/;
use Any::Moose;

has cache => (
  is => 'ro',
  isa => 'Cache::File',
  lazy => 1,
  default => sub {
    Cache::File->new(cache_root => $_[0]->cache_root);
  }
);

has locks => (
  is => 'ro',
  isa => 'HashRef',
  default => sub {{}},
);

has cache_root => (
  is => 'ro',
  isa => 'Str',
  default => sub {dir('./cache/images')->absolute->stringify}
);

has max_size => (
  is => 'ro',
  isa => 'Int',
  default => 2097152,
);

has req_headers => (
  is => 'ro',
  isa => 'HashRef',
  default => sub {
    {"User-Agent" => "Mozilla/5.0 (Macintosh; U; Intel Mac OS X; en) AppleWebKit/419.3 (KHTML, like Gecko) Safari/419.3"}
  }
);

has toolarge => (
  is => 'ro',
  default => sub {
    open my $img, '<', 'static/image/TooLarge.gif';
    my @lines = <$img>;
    close $img;
    return join '', @lines;
  }
);

has badformat => (
  is => 'ro',
  default => sub {
    open my $img, '<', 'static/image/BadFormat.gif';
    my @lines = <$img>;
    close $img;
    return join '', @lines;
  }
);

sub to_app {
  my $self = shift;
  return sub {
    $self->call(@_);
  };
}

sub call {
  my ($self, $env) = @_;
  my $url = uri_escape($env->{'PATH_INFO'}, " ") || '';
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
  if ($url and $url =~ /^https?:\/\//) {
    my $body = '';
    my $length = 0;
    http_get $url,
      headers => $self->req_headers,
      on_header => sub {$self->check_headers(@_, $url)},
      on_body => sub {
        my ($partial, $headers) = @_;
        my $tmp_length = $length + length($partial);
        if ($tmp_length > $self->max_size) {
          $self->complete($self->toolarge, $headers, $url);
          return 0;
        }
        $body .= $partial;
        $length = $tmp_length;
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
  return if $headers->{Status} and $headers->{Status} == 598;
  if (!$body) {
    $self->complete($self->badformat,
      {'Content-Type','image/gif'}, $url);
    return
  }
  elsif (length($body) > $self->max_size) {
    $body = $self->toolarge;
  }
  if (my $mime = $self->get_mime($body, $url)) {
    $self->lock_respond($url, sub {
      [200, ["Content-Type", $mime], [$body]];
    });
    $self->cache->set($url, freeze [$mime, $body]);
  }
}

sub get_mime {
  my ($self, $blob, $url) = @_;
  my $image = Image::Magick->new;
  $image->BlobToImage($blob);
  my $mime = $image->Get('mime');
  undef $image;
  if ($mime !~ /^image/) {
    $self->complete($self->badformat,
      {'Content-Type','image/gif'}, $url);
    return undef;
  }
  return $mime;
}

sub check_headers {
  my ($self, $headers, $url) = @_;
  if ($headers->{Status} != 200) {
    $self->error("got $headers->{Status} for $url", $url);
    return 0;
  }
  if ($headers->{'content-length'} and $headers->{'content-length'} > $self->max_size) {
    $self->complete($self->toolarge,
      {'Content-Type','image/gif'}, $url);
    return 0;
  }
  elsif ($headers->{'content-type'} and $headers->{'content-type'} !~ /^image/) {
    $self->complete($self->badformat,
      {'Content-Type','image/gif'}, $url);
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
