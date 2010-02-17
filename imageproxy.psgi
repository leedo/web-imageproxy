use Plack::Builder;
use lib 'lib';
use Web::ImageProxy;

my $app = Web::ImageProxy->new(
  cache_root => "./cache"
);

builder {
  mount '/' => $app->to_app;
}
