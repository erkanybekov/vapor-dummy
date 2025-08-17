# ================================
# Build image
# ================================
FROM swift:5.9-jammy as build

# Install OS updates and dependencies
RUN export DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true \
    && apt-get -q update \
    && apt-get -q dist-upgrade -y \
    && apt-get -q install -y \
      ca-certificates \
      tzdata \
      libcurl4 \
      libxml2 \
      libssl-dev \
      libpq-dev \
    && rm -r /var/lib/apt/lists/*

# Set up a build area
WORKDIR /build

# First just resolve dependencies.
COPY ./Package.* ./
RUN swift package resolve $([ -f ./Package.resolved ] && echo "--force-resolved-versions" || true)

# Copy entire repo into container
COPY . .

# Build everything, with optimizations
RUN swift build -c release --static-swift-stdlib

# Switch to the staging area
WORKDIR /staging

# Copy main executable to staging area
RUN cp "$(swift build --package-path /build -c release --show-bin-path)/hello" ./

# Copy resources bundled by SPM to staging area
RUN find -L "$(swift build --package-path /build -c release --show-bin-path)/" -regex '.*\.resources$' -exec cp -Ra {} ./ \; || true

# Copy any resources from the public directory and views directory if the directories exist
RUN [ -d /build/Public ] && { mv /build/Public ./Public && chmod -R a-w ./Public; } || true
RUN [ -d /build/Resources ] && { mv /build/Resources ./Resources && chmod -R a-w ./Resources; } || true

# ================================
# Run image
# ================================
FROM ubuntu:jammy

# Make sure all system packages are up to date
RUN export DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true \
    && apt-get -q update \
    && apt-get -q dist-upgrade -y \
    && apt-get -q install -y \
      ca-certificates \
      tzdata \
      libcurl4 \
      libxml2 \
      libssl3 \
      libpq5 \
    && rm -r /var/lib/apt/lists/*

# Create a vapor user and group with /app as its home directory
RUN useradd --user-group --create-home --system --skel /dev/null --home-dir /app vapor

# Switch to the new home directory
WORKDIR /app

# Copy built executable and any staged resources from builder
COPY --from=build --chown=vapor:vapor /staging /app

# Ensure all further commands run as the vapor user
USER vapor:vapor

# Let Docker bind to port 10000 (Render's default)
EXPOSE 10000

# Start the Vapor service when the image is run
ENTRYPOINT ["./hello"]
CMD ["serve", "--env", "production", "--hostname", "0.0.0.0", "--port", "10000"]
