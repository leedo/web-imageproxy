use Plack::Builder;
use lib 'lib';
use Web::ImageProxy;

my $app = Web::ImageProxy->new;

builder {
  mount '/' => $app->to_app;
}
