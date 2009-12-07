package Plack::App::ImageProxy;

use strict;
use warnings;

use Digest::MD5 qw/md5_hex/;
use Path::Class qw/dir/;
use Plack::Request;
use AnyEvent::HTTP;

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
  isa => 'HashRef[ArrayRef]',
  default => sub {{}},
);

sub call {
  my ($self, $env) = @_;
  my $req = Plack::Request->new($env);
  my $res = $req->new_response;
  my $path = $req->uri->path;
  $path =~ s/^\///;
  my $uri = URI->new($path);
  my $hash = md5_hex $path;
  if ($self->has_lock($hash)) { # downloading
    return sub {
      my $cb = shift;
      $self->add_lock_response($hash, [$res, $cb])
    };
  }
  elsif ($self->cache_root->contains($self->cache_root->file($hash))) { #exists
    $res->status(200);
    $res->content_type("image/jpeg");
    $res->body($self->cache_root->file($hash)->openr);
    $res->finalize;
  }
  else { # new download
    return sub {
      my $cb = shift;
      $self->add_lock_response($hash, [$res, $cb]); 
      $self->download($uri, $hash);
    };
  }
}


sub download {
  my ($self, $uri, $hash) = @_;
  if ($uri->scheme and $uri->scheme eq "http") {
    http_get $uri->as_string,
      headers => $self->req_headers,
      on_header => sub {$self->check_headers(@_, $hash)},
      sub {$self->complete(@_, $hash)};
  }
  else {
    $self->error("invalid url", $hash);
  }
}

sub complete {
  my ($self, $body, $headers, $hash) = @_;
  return if $headers->{Status} == 598;
  if ($body) {
    my $file = $self->cache_root->file($hash);
    my $fh = $file->openw;
    print $fh $body;
    close $fh;
    $self->lock_respond($hash, sub {
      my $res = shift;
      $res->status(200);
      $res->content_type("image/jpeg");
      $res->body($file->openr);
      $res->finalize;
    });
  }
  else {
    $self->error("empty response body", $hash);
  }
}

sub check_headers {
  my ($self, $headers, $hash) = @_;
  if ($headers->{Status} != 200) {
    $self->error("got $headers->{Status}", $hash);
    return 0;
  }
  if ($headers->{'content-length'} and $headers->{'content-length'} > $self->max_size) {
    $self->error("too large", $hash);
    return 0;
  }
  elsif ($headers->{'content-type'} and $headers->{'content-type'} !~ /^image/) {
    $self->error("invalid content type", $hash);
    return 0;
  }
  return 1;
}

sub error {
  my ($self, $error, $hash) = @_;
  $self->lock_respond($hash, sub {
    my $res = shift;
    $res->status(404);
    $res->content_type("text/plain");
    $res->body("error: $error");
    $res->finalize;
  });
}

sub lock_respond {
  my ($self, $hash, $cb) = @_;
  if ($self->has_lock($hash)) {
    for my $res ($self->get_lock_responses($hash)) {
      $res->[1]->(
        $cb->($res->[0])
      );
    }
    $self->remove_lock($hash);
  }
}

sub has_lock {
  my ($self, $hash) = @_;
  exists $self->response_locks->{$hash};
}

sub locks {
  my ($self, $hash) = @_;
  keys %{$self->response_locks};
}

sub get_lock_responses {
  my ($self, $hash) = @_;
  @{$self->response_locks->{$hash}};
}

sub add_lock_response {
  my ($self, $hash, $res) = @_;
  if ($self->has_lock($hash)) {
    push @{$self->response_locks->{$hash}}, $res;
  }
  else {
    $self->response_locks->{$hash} = [$res];
  }
}

sub remove_lock {
  my ($self, $hash) = @_;
  delete $self->response_locks->{$hash};
}

__PACKAGE__->meta->make_immutable;
no Moose;

1;