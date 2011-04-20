use lib 'lib';
use Web::ImageProxy;

Web::ImageProxy->new(cache_root => "./cache")->to_app;
