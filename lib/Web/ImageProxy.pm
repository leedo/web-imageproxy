package Web::ImageProxy;

use strict;
use warnings;

use CHI;
use Path::Class qw/dir file/;
use URI::Escape;
use AnyEvent::HTTP;
use Any::Moose;
use List::Util qw/shuffle/;
use File::Spec::Functions qw/splitdir/;

use constant MONTH => 2419200;

has cache => (
  is => 'ro',
  lazy => 1,
  default => sub {
    CHI->new(
      driver => "File",
      root_dir => $_[0]->cache_root,
      expires_in => MONTH,
    );
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
  default => sub {dir('./cache')->absolute->stringify}
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
    {
      "User-Agent" => "Mozilla/5.0 (Macintosh; U; Intel Mac OS X; en) AppleWebKit/419.3 (KHTML, like Gecko) Safari/419.3",
      "Referer" => undef,
    }
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

sub randomimage {
  my ($self, $dir) = @_;

  my $base = dir($dir || $self->cache->path_to_namespace);

  my @children = shuffle $base->children;
  my @files = grep {!$_->is_dir and $_ !~ /meta/} @children;

  if (@files) {
    my $root = $self->cache->path_to_namespace;
    for my $file (@files) {

      # strip off .dat
      my $key = substr $file->basename, 0, -4;

      # convert filename to url
      $key =~ s/(https?)\+3a\+2f\+2f/$1\:\/\//;
      $key =~ s/\+([0-9a-z])/%$1/g;
      $key = uri_unescape($key);

      my $meta = $self->cache->get("$key-meta");
      if ($key and $meta and !$meta->{error}) {
        return [200, $meta->{headers}, $file->openr];
      }
    }
  }

  # recurse into directories if there are no files
  my @dirs = grep {$_->is_dir} @children;
  for my $dir (@dirs) {
    my $ret = $self->randomimage($dir);
    return $ret if $ret;
  }

  # return 404 if no images were found in any directory, shouldn't happen
  if (!$dir) {
    return [200, ['Content-Type', 'text/plain'], ['no images']];
  }

  return ();
}

sub call {
  my ($self, $env) = @_;

  my $url = build_url($env);
  return $self->randomimage unless $url;

  if ($self->has_lock($url)) { # downloading
    return sub {
      my $cb = shift;
      $self->add_lock_callback($url, $cb);
    };
  }

  my $file = file($self->cache->path_to_key($url));
  my $meta = $self->cache->get("$url-meta");
  my $uncache = $url =~ /\?.*uncache=1/;

  if (!$uncache and $meta) { # info cached
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
  my $req;
  my $length = 0;
  my $cache = file($self->cache->path_to_key($url));
  $cache->parent->mkpath;
  my $timer = AnyEvent->timer( after => 61, cb => sub {
    if ($self->has_lock($url)) {
      print STDERR "download timed out for $url\n";
      $self->lock_respond($url, $self->cannotread);
      undef $req;
    }
  });
  $req = http_get $url,
    headers => $self->req_headers,
    on_header => sub {$self->check_headers(@_, $url)},
    timeout => 60,
    want_body_handle => 1,
    sub {
      my ($handle, $headers) = @_;
      my $cancel = sub {
        undef $timer;
        undef $handle;
        undef $req;
      };
      if ($headers->{Status} != 200) {
        print STDERR "got $headers->{Status} for $url: $headers->{Reason}\n";
        $self->lock_respond($url, $self->cannotread);
        return;
      }
      return unless $handle;
      my $fh = $cache->openw;
      $handle->on_read(sub {
        my $data = delete $_[0]->{rbuf};
        $length += length $data;
        if ($length > $self->max_size) {
          $self->lock_respond($url, $self->toolarge);
          $cache->remove;
          $cancel->();
        }
        else {
          print $fh $data;
        }
      });
      $handle->on_error(sub{
        my (undef, undef, $error) = @_;
        print STDERR "got an error downloading $url: $error\n";
        $self->lock_respond($url, $self->cannotread);
        $cancel->();
      });
      $handle->on_eof(sub {
        $cancel->();
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
    print STDERR "got $headers->{Status} for $url: $headers->{Reason}\n";
    $self->lock_respond($url, $self->cannotread);
    return 0;
  }
  if ($length and $length > $self->max_size) {
    $self->lock_respond($url, $self->toolarge);
    #$self->cache->set("$url-meta", {error => "toolarge"});
    return 0;
  }
  if (!$type or $type !~ /^(?:image|(?:application|binary)\/octet-stream)/) {
    $self->lock_respond($url, $self->badformat);
    #$self->cache->set("$url-meta", {error => "badformat"});
    return 0;
  }
  return 1;
}

sub build_url {
  my $env = shift;
  my $base_path = $env->{SCRIPT_NAME} || '/';
  my $url = $base_path . ($env->{REQUEST_URI} || '');
  $url =~ s{^/+}{};
  return if !$url or $url eq "/";
  $url = "http://$url" unless $url =~ /^https?/;
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
