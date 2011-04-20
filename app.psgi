use Plack::Builder;
use lib 'lib';
use Web::ImageProxy;

builder {
  mount "/" => Web::ImageProxy->new(cache_root => "./cache")->to_app;
}
