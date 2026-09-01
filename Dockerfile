ARG IMAGEMAGICK_VERSION=7.1.2-30
ARG PERL_VERSION=5.44.0

FROM ubuntu:latest AS builder

ARG IMAGEMAGICK_VERSION
ARG PERL_VERSION

WORKDIR /opt/web-imageproxy

RUN apt-get update && apt-get -y install \
    curl \
    build-essential \
    libssl-dev \
    zlib1g-dev \
    perl \
    cpanminus \
    libgif-dev \
    libpng-dev \
    libjpeg8-dev \
    libheif-dev \
    libde265-dev \
    libwebp-dev \
    libtiff-dev \
    libdav1d-dev \
    libtool \
    && rm -rf /var/lib/apt/lists/*

RUN curl -s -L https://github.com/ImageMagick/ImageMagick/archive/refs/tags/${IMAGEMAGICK_VERSION}.tar.gz | tar -xvzf - -C /tmp
RUN cd /tmp/ImageMagick-${IMAGEMAGICK_VERSION} \
    && ./configure --with-png=yes --with-jpeg=yes --with-heic=yes --with-webp=yes \
    && make -j$(nproc) \
    && make install

RUN cpanm -nq Perl::Build
RUN perl-build -j4 $PERL_VERSION /opt/perl-$PERL_VERSION

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

RUN apt-get update && apt-get -y install \
    libgomp1 \
    libssl3t64 \
    libjpeg8 \
    libgif7 \
    libpng16-16t64 \
    libheif1 \
    libde265-0 \
    libwebp7 \
    libtiff6 \
    libdav1d7 \
    && rm -rf /var/lib/apt/lists/*

COPY . /opt/web-imageproxy
COPY --from=builder /usr/local/lib/* /usr/local/lib
COPY --from=builder /opt/web-imageproxy/local /opt/web-imageproxy/local
COPY --from=builder /opt/perl-${PERL_VERSION} /opt/perl-${PERL_VERSION}

CMD ["perl", "-Ilocal/lib/perl5", "local/bin/plackup", "-E", "prod", "--server", "Twiggy", "-Ilib", "--listen", ":5007", "app.psgi"]
