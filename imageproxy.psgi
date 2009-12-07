use Plack::Builder;
use lib 'lib';
use Plack::App::ImageProxy;

my $app = Plack::App::ImageProxy->new;

builder {
  mount '/' => $app->to_app;
}