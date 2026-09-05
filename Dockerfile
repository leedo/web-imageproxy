ARG IMAGEMAGICK_VERSION=7.1.2-31
ARG PERL_VERSION=5.44.0

FROM ubuntu:latest AS builder

ARG IMAGEMAGICK_VERSION
ARG PERL_VERSION

WORKDIR /opt/web-imageproxy

RUN apt-get -y update && apt-get -y install \
    curl \
    build-essential \
    libssl-dev \
    perl \
    cpanminus \
    zlib1g-dev \
    libgif-dev \
    libpng-dev \
    libde265-dev \
    libheif-dev \
    libjemalloc-dev \
    libjpeg-dev \
    liblzma-dev \
    libraw-dev \
    librsvg2-dev \
    libtiff-dev \
    libwebp-dev \
    libzip-dev \
    libzstd-dev \
    libtool \
    && rm -rf /var/lib/apt/lists/*

RUN curl -s -L https://github.com/ImageMagick/ImageMagick/archive/refs/tags/${IMAGEMAGICK_VERSION}.tar.gz | tar -xvzf - -C /tmp
RUN cd /tmp/ImageMagick-${IMAGEMAGICK_VERSION} \
    && ./configure \
      --with-png=yes \
      --with-jpeg=yes \
      --with-heic=yes \
      --with-webp=yes \
      --with-lzma=yes \
      --with-zlib=yes \
      --with-zstd=yes \
      --with-gcc-arch=native \
      --disable-static \
      --disable-docs \
      --without-magick-plus-plus \
    && make -j$(nproc) \
    && make install-strip

RUN cpanm -nq Perl::Build
RUN perl-build --noman -j4 $PERL_VERSION /opt/perl-$PERL_VERSION

ENV PATH="/opt/perl-${PERL_VERSION}/bin:${PATH}"

RUN curl -L https://cpanmin.us | perl - App::cpanminus
RUN cpanm -nq Carmel

COPY cpanfile cpanfile.snapshot /opt/web-imageproxy/

RUN carmel install
RUN carmel rollout

RUN cpanm -L local AnyEvent::AIO

FROM ubuntu:latest AS imageproxy

ARG PERL_VERSION

WORKDIR /opt/web-imageproxy

ENV PATH="/opt/perl-${PERL_VERSION}/bin:${PATH}"

RUN apt-get -y update && apt-get -y install --no-install-recommends \
    libgomp1 \
    libssl3t64 \
    zlib1g \
    libpng16-16t64 \
    libheif1 \
    libjpeg-turbo8 \
    liblzma5 \
    libraw23t64 \
    libtiff6 \
    libwebp7 \
    libwebpdemux2 \
    libwebpmux3 \
    libzip5 \
    libzstd1 \
    liblcms2-2 \
    libxml2-16 \
    libfreetype6 \
    libfontconfig1 \
    libcairo2 \
    libpangocairo-1.0-0 \
    libx11-6 \
    libxext6 \
    libjemalloc2 \
    && rm -rf /var/lib/apt/lists/*

COPY . /opt/web-imageproxy
COPY --from=builder /usr/local/lib/ /usr/local/lib/
COPY --from=builder /opt/web-imageproxy/local /opt/web-imageproxy/local
COPY --from=builder /opt/perl-${PERL_VERSION} /opt/perl-${PERL_VERSION}

RUN ldconfig

CMD ["perl", "-Ilocal/lib/perl5", "local/bin/plackup", "-E", "prod", "--server", "Twiggy", "-Ilib", "--listen", ":5007", "app.psgi"]
