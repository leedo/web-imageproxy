package Plack::App::ImageProxy;

use strict;
use warnings;

use Path::Class qw/dir/;
use Cache::File;
use Plack::Request;
use Plack::Response;
use AnyEvent::HTTP;
use Image::Magick;

use Moose;
use MooseX::NonMoose;
use MooseX::Types::Path::Class;

extends 'Plack::Middleware';

has cache_root => (
  is => 'ro',
  isa => 'Path::Class::Dir',
  required => 1,
  coerce => 1,
  default => sub {dir('./cache/images/')},
);

has cache => (
  is => 'ro',
  isa => 'Cache::File',
  lazy => 1,
  default => sub {
    Cache::File->new(cache_root => $_[0]->cache_root->absolute);
  }
);

has max_size => (
  is => 'ro',
  isa => 'Int',
  default => 2097152
);

has req_headers => (
  is => 'ro',
  isa => 'HashRef',
  default => sub {
    {
      "User-Agent" => "Mozilla/5.0 (Macintosh; U; Intel Mac OS X; en) AppleWebKit/419.3 (KHTML, like Gecko) Safari/419.3",
    }
  }
);

has response_locks => (
  is => 'rw',
  isa => 'HashRef[CodeRef]',
  default => sub {{}},
);

sub call {
  my ($self, $env) = @_;
  my $req = Plack::Request->new($env);
  my $url = $req->uri->path;
  $url =~ s/^\///;
  if ($self->has_lock($url)) { # downloading
    return sub {
      my $cb = shift;
      $self->add_lock_callback($url, $cb);
    };
  }
  elsif (my $image = $self->cache->get($url)) {
    if (my $mime = $self->get_mime($image, $url)) {
      my $res = $req->new_response;
      $res->status(200);
      $res->content_type($mime);
      $res->body($image);
      return $res->finalize;
    }
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
        my $res = Plack::Response->new;
        $res->status(200);
        $res->content_type($mime);
        $res->body($body);
        $res->finalize;
      });
      $self->cache->set($url, $body);
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
  $self->lock_respond($url, sub {
    my $res = Plack::Response->new;
    $res->status(404);
    $res->content_type("text/plain");
    $res->body("error: $error");
    $res->finalize;
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
  exists $self->response_locks->{$url};
}

sub locks {
  my ($self, $url) = @_;
  keys %{$self->response_locks};
}

sub get_lock_callbacks {
  my ($self, $url) = @_;
  @{$self->response_locks->{$url}};
}

sub add_lock_callback {
  my ($self, $url, $cb) = @_;
  if ($self->has_lock($url)) {
    push @{$self->response_locks->{$url}}, $cb;
  }
  else {
    $self->response_locks->{$url} = [$cb];
  }
}

sub remove_lock {
  my ($self, $url) = @_;
  delete $self->response_locks->{$url};
}

__PACKAGE__->meta->make_immutable;
no Moose;

1;
