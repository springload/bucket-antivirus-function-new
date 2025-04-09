FROM amazonlinux:2023
# Set up working directories
RUN mkdir -p /opt/app
RUN mkdir -p /opt/app/build
RUN mkdir -p /opt/app/bin/

# Copy in the lambda source
WORKDIR /opt/app
COPY ./*.py /opt/app/
COPY requirements.txt /opt/app/requirements.txt

# Install base packages
RUN dnf update -y && \
    dnf install -y cpio tar gzip zip python3-pip shadow-utils \
    wget json-c pcre2 && \
    pip3 install -r requirements.txt && \
    rm -rf /root/.cache/pip

# Download and install ClamAV 1.4.2 RPM
WORKDIR /tmp
RUN wget https://www.clamav.net/downloads/production/clamav-1.4.2.linux.x86_64.rpm && \
    dnf install -y ./clamav-1.4.2.linux.x86_64.rpm

# Download libraries we need to run in lambda
RUN mkdir -p /opt/app/bin

# Copy over the binaries and libraries
RUN cp -f /usr/local/bin/clamscan /opt/app/bin/ || cp -f /usr/bin/clamscan /opt/app/bin/ && \
    cp -f /usr/local/bin/freshclam /opt/app/bin/ || cp -f /usr/bin/freshclam /opt/app/bin/ && \
    # Copy system libraries needed by ClamAV \
    cp -f /lib64/libm.so.6 /opt/app/bin/ && \
    cp -f /lib64/libc.so.6 /opt/app/bin/ && \
    cp -f /lib64/ld-linux-x86-64.so.2 /opt/app/bin/ && \
    # Try to locate libclamav and copy from the correct location \ENV CLAMAVLIB_PATH=/var/task/bin
    find / -name "libclamav.so*" 2>/dev/null | while read lib; do \
        cp -f $lib /opt/app/bin/; \
    done && \
    # Copy other required libraries \
    cp -f /usr/lib64/libjson-c.so* /opt/app/bin/ && \
    cp -f /usr/lib64/libpcre2*.so* /opt/app/bin/ && \
    cp -f /usr/lib64/libltdl.so* /opt/app/bin/ || true && \
    cp -f /usr/lib64/libxml2.so* /opt/app/bin/ && \
    cp -f /usr/lib64/libbz2.so* /opt/app/bin/ && \
    cp -f /usr/lib64/libz.so* /opt/app/bin/ && \
    cp -f /usr/lib64/libcurl.so* /opt/app/bin/ && \
    cp -f /usr/lib64/libnghttp2.so* /opt/app/bin/ || true && \
    cp -f /usr/lib64/libidn2.so* /opt/app/bin/ && \
    cp -f /usr/lib64/libssh2.so* /opt/app/bin/ || true && \
    cp -f /usr/lib64/libssl.so* /opt/app/bin/ && \
    cp -f /usr/lib64/libcrypto.so* /opt/app/bin/ && \
    cp -f /usr/lib64/libgssapi_krb5.so* /opt/app/bin/ || true && \
    cp -f /usr/lib64/libkrb5.so* /opt/app/bin/ || true && \
    cp -f /usr/lib64/libk5crypto.so* /opt/app/bin/ || true && \
    cp -f /usr/lib64/libcom_err.so* /opt/app/bin/ || true && \
    cp -f /usr/lib64/libldap*.so* /opt/app/bin/ || true && \
    cp -f /usr/lib64/liblber*.so* /opt/app/bin/ || true && \
    cp -f /usr/lib64/libunistring.so* /opt/app/bin/ || true && \
    cp -f /usr/lib64/libsasl2.so* /opt/app/bin/ || true && \
    # Copy any additional libraries that ClamAV 1.4.2 might need \
    find /usr/local/lib* -name "*.so*" 2>/dev/null | while read lib; do \
        cp -f $lib /opt/app/bin/ || true; \
    done

# Copy ClamAV shared libs explicitly
RUN cp -f /usr/local/lib64/libclamav.so* /opt/app/bin/ && \
    cp -f /usr/local/lib64/libclammspack.so* /opt/app/bin/ && \
    cp -f /usr/local/lib64/libfreshclam.so* /opt/app/bin/ || true

# Create users for clamav
RUN groupadd clamav || true
RUN useradd -g clamav -s /bin/false -c "Clam Antivirus" clamav || true
RUN useradd -g clamav -s /bin/false -c "Clam Antivirus" clamupdate || true

# Fix the freshclam.conf settings
RUN echo "DatabaseMirror database.clamav.net" > /opt/app/bin/freshclam.conf && \
    echo "CompressLocalDatabase yes" >> /opt/app/bin/freshclam.conf && \
    echo "ScriptedUpdates no" >> /opt/app/bin/freshclam.conf && \
    echo "DatabaseDirectory /var/lib/clamav" >> /opt/app/bin/freshclam.conf

# Set the library path and update ldconfig
ENV LD_LIBRARY_PATH=/var/task/bin
ENV CLAMAVLIB_PATH=/var/task/bin
RUN ldconfig



# Check ClamAV version
RUN echo "ClamAV version:" && LD_LIBRARY_PATH=/opt/app/bin /opt/app/bin/clamscan --version

# Create the zip file
WORKDIR /opt/app
RUN zip -r9 --exclude="*test*" /opt/app/build/anti-virus.zip *.py bin

# Add Python packages to the zip file
RUN python_version=$(python3 -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')") && \
    site_packages="/usr/local/lib/python${python_version}/site-packages" && \
    if [ -d "$site_packages" ]; then \
        cd "$site_packages" && \
        zip -r9 /opt/app/build/anti-virus.zip * || echo "No files in site-packages"; \
    else \
        echo "Site packages directory not found at $site_packages"; \
        site_packages=$(pip3 show datadog 2>/dev/null | grep Location | awk '{print $2}') && \
        if [ -n "$site_packages" ]; then \
            echo "Found site-packages at: $site_packages"; \
            cd "$site_packages" && \
            zip -r9 /opt/app/build/anti-virus.zip * || echo "No files in $site_packages"; \
        else \
            echo "Could not locate Python site-packages. Attempting to find it..."; \
            find /usr -type d -name "site-packages" | while read dir; do \
                echo "Found site-packages at: $dir"; \
                cd "$dir" && \
                zip -r9 /opt/app/build/anti-virus.zip * || echo "No files in $dir"; \
                break; \
            done; \
        fi; \
    fi

WORKDIR /opt/app
