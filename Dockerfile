ARG IMAGEMAGICK_VERSION=7.1.2-30
ARG PERL_VERSION=5.44.0

FROM ubuntu:latest AS builder

ARG IMAGEMAGICK_VERSION
ARG PERL_VERSION

WORKDIR /opt/web-imageproxy

RUN apt-get update && apt-get -y install curl build-essential libssl-dev zlib1g-dev perl cpanminus

RUN curl -s -L https://github.com/ImageMagick/ImageMagick/archive/refs/tags/${IMAGEMAGICK_VERSION}.tar.gz | tar -xvzf - -C /tmp
RUN cd /tmp/ImageMagick-${IMAGEMAGICK_VERSION} \
    && ./configure \
    && make \
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

RUN apt-get update && apt-get -y install libgomp1 libssl3t64
COPY . /opt/web-imageproxy
COPY --from=builder /usr/local/lib/* /usr/local/lib
COPY --from=builder /opt/web-imageproxy/local /opt/web-imageproxy/local
COPY --from=builder /opt/perl-${PERL_VERSION} /opt/perl-${PERL_VERSION}

CMD ["perl", "-Ilocal/lib/perl5", "local/bin/plackup", "--server", "Twiggy", "-Ilib", "--listen", ":5007", "app.psgi"]
