FROM public.ecr.aws/lambda/python:3.12
# Set up working directories
RUN mkdir -p /opt/app
RUN mkdir -p /opt/app/build
RUN mkdir -p /opt/app/bin/

# Copy in the lambda source
WORKDIR /opt/app
COPY ./*.py /opt/app/
COPY requirements.txt /opt/app/requirements.txt

# Install base packages
# Lambda base image uses microdnf (minimal package manager)
RUN microdnf update -y && \
    microdnf install -y tar gzip zip shadow-utils wget findutils && \
    pip3 install -r requirements.txt && \
    rm -rf /root/.cache/pip

# Download and install ClamAV 1.4.2 RPM
# Note: microdnf cannot install local RPM files, so we use rpm -Uvh directly
WORKDIR /tmp
RUN wget https://www.clamav.net/downloads/production/clamav-1.4.2.linux.x86_64.rpm && \
    rpm -Uvh --nodeps ./clamav-1.4.2.linux.x86_64.rpm

# Create bin directory for ClamAV binaries and dependencies
RUN mkdir -p /opt/app/bin

# Copy ClamAV binaries
# DO NOT copy core system libraries (libc.so.6, ld-linux-x86-64.so.2, libm.so.6, libgcc_s.so.1)
# These will be provided by the Lambda runtime environment
RUN cp -f /usr/local/bin/clamscan /opt/app/bin/ || cp -f /usr/bin/clamscan /opt/app/bin/ && \
    cp -f /usr/local/bin/freshclam /opt/app/bin/ || cp -f /usr/bin/freshclam /opt/app/bin/

# Copy ClamAV shared libraries
RUN find /usr/local/lib64 -name "libclamav.so*" 2>/dev/null -exec cp -f {} /opt/app/bin/ \; && \
    find /usr/lib64 -name "libclamav.so*" 2>/dev/null -exec cp -f {} /opt/app/bin/ \; && \
    find /usr/local/lib64 -name "libclammspack.so*" 2>/dev/null -exec cp -f {} /opt/app/bin/ \; && \
    find /usr/lib64 -name "libclammspack.so*" 2>/dev/null -exec cp -f {} /opt/app/bin/ \; && \
    find /usr/local/lib64 -name "libfreshclam.so*" 2>/dev/null -exec cp -f {} /opt/app/bin/ \; && \
    find /usr/lib64 -name "libfreshclam.so*" 2>/dev/null -exec cp -f {} /opt/app/bin/ \;

# Copy only essential application-level dependencies
# These are libraries that ClamAV needs but are NOT in Lambda runtime
# DO NOT copy runtime-provided libs (libssl, libcrypto, libcurl, kerberos/ldap libs)
RUN cp -f /usr/lib64/libjson-c.so* /opt/app/bin/ 2>/dev/null || true && \
    cp -f /usr/lib64/libpcre2*.so* /opt/app/bin/ 2>/dev/null || true && \
    cp -f /usr/lib64/libltdl.so* /opt/app/bin/ 2>/dev/null || true && \
    cp -f /usr/lib64/libxml2.so* /opt/app/bin/ 2>/dev/null || true && \
    cp -f /usr/lib64/libbz2.so* /opt/app/bin/ 2>/dev/null || true && \
    cp -f /usr/lib64/libz.so* /opt/app/bin/ 2>/dev/null || true

# Create users for clamav
RUN groupadd clamav || true
RUN useradd -g clamav -s /bin/false -c "Clam Antivirus" clamav || true
RUN useradd -g clamav -s /bin/false -c "Clam Antivirus" clamupdate || true

# Fix the freshclam.conf settings
RUN echo "DatabaseMirror database.clamav.net" > /opt/app/bin/freshclam.conf && \
    echo "CompressLocalDatabase yes" >> /opt/app/bin/freshclam.conf && \
    echo "ScriptedUpdates no" >> /opt/app/bin/freshclam.conf && \
    echo "DatabaseDirectory /var/lib/clamav" >> /opt/app/bin/freshclam.conf

# Set the library path
# Note: We rely on Lambda runtime's core system libraries (libc, ld-linux, libssl, libcrypto, libcurl, etc.)
ENV LD_LIBRARY_PATH=/var/task/bin
ENV CLAMAVLIB_PATH=/var/task/bin

# Verify ClamAV installation and dependencies
# This will fail the build if there are missing dependencies, making issues obvious
RUN echo "Verifying clamscan dependencies:" && \
    ldd /opt/app/bin/clamscan && \
    echo "Testing clamscan:" && \
    LD_LIBRARY_PATH=/opt/app/bin /opt/app/bin/clamscan --version

# Create the zip file
WORKDIR /opt/app
RUN zip -r9 --exclude="*test*" /opt/app/build/anti-virus.zip *.py bin

# Add Python packages to the zip file
# Lambda base image uses /var/lang/lib/python3.12/site-packages
RUN python_version=$(python3 -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')") && \
    site_packages="/var/lang/lib/python${python_version}/site-packages" && \
    if [ -d "$site_packages" ]; then \
        echo "Found site-packages at: $site_packages"; \
        cd "$site_packages" && \
        zip -r9 /opt/app/build/anti-virus.zip * || echo "No files in site-packages"; \
    else \
        echo "Site packages directory not found at $site_packages, searching..."; \
        site_packages=$(pip3 show datadog 2>/dev/null | grep Location | awk '{print $2}') && \
        if [ -n "$site_packages" ]; then \
            echo "Found site-packages at: $site_packages"; \
            cd "$site_packages" && \
            zip -r9 /opt/app/build/anti-virus.zip * || echo "No files in $site_packages"; \
        else \
            find /var/lang /usr -type d -name "site-packages" 2>/dev/null | while read dir; do \
                echo "Found site-packages at: $dir"; \
                cd "$dir" && \
                zip -r9 /opt/app/build/anti-virus.zip * || echo "No files in $dir"; \
                break; \
            done; \
        fi; \
    fi

WORKDIR /opt/app
