package Web::ImageProxy;

use strict;
use warnings;

use CHI;
use Path::Class qw/dir file/;
use URI::Escape;
use AnyEvent::HTTP;
use Any::Moose;

has cache => (
  is => 'ro',
  lazy => 1,
  default => sub {
    CHI->new(driver => "File", root_dir => $_[0]->cache_root);
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
    my $file = file("static/image/TooLarge.gif");
    [
      200,
      ["Content-Type", "image/gif", "Content-Length", $file->stat->size],
      $file->openr
    ];
  }
);

has badformat => (
  is => 'ro',
  default => sub {
    my $file = file('static/image/BadFormat.gif');
    [
      200,
      ["Content-Type", "image/gif", "Content-Length", $file->stat->size],
      $file->openr
    ];
  }
);

has cannotread => (
  is => 'ro',
  default => sub {
    my $file = file('static/image/CannotRead.gif');
    [
      200,
      ["Content-Type", "image/gif", "Content-Length", $file->stat->size],
      $file->openr
    ];
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

  my $url = build_url($env);
  return $self->cannotread unless $url;

  if ($self->has_lock($url)) { # downloading
    return sub {
      my $cb = shift;
      $self->add_lock_callback($url, $cb);
    };
  }

  my $file = file($self->cache->path_to_key($url));
  my $meta = $self->cache->get("$url-meta");

  if ($meta) { # info cached
    my $resp;
    if (my $error = $meta->{error}) {
      return $self->$error;
    }
    elsif ($meta->{headers} and -e $file->absolute->stringify) {
      return [200, $meta->{headers}, $file->openr];
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
  my $length = 0;
  my $cache = file($self->cache->path_to_key($url));
  $cache->parent->mkpath;
  my $req; $req = http_get $url,
    headers => $self->req_headers,
    on_header => sub {$self->check_headers(@_, $url)},
    timeout => 60,
    want_body_handle => 1,
    sub {
      my ($handle, $headers) = @_;
      return unless $handle;
      my $fh = $cache->openw;
      $handle->on_read(sub {
        my $data = delete $_[0]->{rbuf};
        $length += length $data;
        if ($length > $self->max_size) {
          $self->lock_respond($url, $self->toolarge);
          $cache->remove;
          $handle->destroy;
          undef $handle;
          undef $req;
        }
        else {
          print $fh $data;
        }
      });
      $handle->on_error(sub{
        $self->lock_respond($url, $self->cannotread);
        $handle->destroy;
        undef $handle;
        undef $req;
      });
      $handle->on_eof(sub {
        $handle->destroy;
        undef $handle;
        undef $req;
        $fh = file($self->cache->path_to_key($url))->openr;
        my $headers = [
          "Content-Type" => $headers->{'content-type'},
          "Content-Length" => $length
        ];
        $self->cache->set("$url-meta", {headers => $headers});
        $self->lock_respond($url,[200, $headers, $fh]);
      });
    }
}

sub check_headers {
  my ($self, $headers, $url) = @_;
  my ($length, $type) = @$headers{'content-length', 'content-type'};
  if ($headers->{Status} != 200) {
    $self->lock_respond($url, $self->cannotread);
    return 0;
  }
  if ($length and $length > $self->max_size) {
    $self->lock_respond($url, $self->toolarge);
    $self->cache->set("$url-meta", {error => "toolarge"});
    return 0;
  }
  if (!$type or $type !~ /^image/) {
    $self->lock_respond($url, $self->badformat);
    $self->cache->set("$url-meta", {error => "badformat"});
    return 0;
  }
  return 1;
}

sub error {
  my ($self, $error, $url) = @_;
  $error = "error: $error";
  $self->lock_respond($url, [404, ["Content-Type", "text/plain"], [$error]]);
}

sub build_url {
  my $env = shift;
  my $base_path = $env->{SCRIPT_NAME} || '/';
  my $url = $base_path . ($env->{PATH_INFO} || '');
  $url =~ s{^/+}{};
  $url = "http://$url" unless $url =~ /^https?/;
  $url .= ($env->{QUERY_STRING} ? "?$env->{QUERY_STRING}" : "");
  $url =~ s/\s/%20/g;
  return $url;
}

sub lock_respond {
  my ($self, $url, $res) = @_;
  if ($self->has_lock($url)) {
    for my $lock_cb ($self->get_lock_callbacks($url)) {
      $lock_cb->( $res);
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
