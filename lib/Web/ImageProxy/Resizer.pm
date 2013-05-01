package Web::ImageProxy::Resizer;

use Image::Magick;

my $counter = 0;
our $overlay = Image::Magick->new;
$overlay->Read("play_overlay.png");

sub resize {
  my ($file, %options) = @_;

  if ($counter++ > 250) {
    AnyEvent::Fork::Pool::retire();
    $counter = 0;
  }

  my $image = Image::Magick->new;
  $image->Read($file);

  my $frames = scalar(@$image) - 1;

  if ($options{still} and $frames > 0) {
    undef $image->[$_] for (1 .. $frames);
    $image->[0]->Composite(
      image => $overlay,
      gravity => "Center",
      compose => "Over",
    );
    $frames = 0;
  }

  # only have one frame, lets resize
  if ($frames == 0) {
    if ($options{width} or $options{height}) {
      my $resize = join "x", ($options{width} || ">"), ($options{height} || ">");
      $image->[0]->Resize($resize);
    }
    $image->[0]->AutoOrient();
    $image->[0]->Write($file);
  }

  undef $image;
}

1;
