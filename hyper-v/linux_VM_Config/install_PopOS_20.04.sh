#!/bin/bash

#
# This script is for Ubuntu 20.04 Focal Fossa to download and install XRDP+XORGXRDP via
# source.
#
# Major thanks to: http://c-nergy.be/blog/?p=11336 for the tips.
#

###############################################################################
# Use HWE kernel packages
#
HWE=""
#HWE="-hwe-20.04"

###############################################################################
# Update our machine to the latest code if we need to.
#

if [ "$(id -u)" -ne 0 ]; then
    echo 'This script must be run with root privileges' >&2
    exit 1
fi

apt update && apt upgrade -y

if [ -f /var/run/reboot-required ]; then
    echo "A reboot is required in order to proceed with the install." >&2
    echo "Please reboot and re-run this script to finish the install." >&2
    exit 1
fi

###############################################################################
# XRDP
#

# Install hv_kvp utils
apt install -y linux-tools-virtual${HWE}
apt install -y linux-cloud-tools-virtual${HWE}

# Install the xrdp service so we have the auto start behavior
apt install -y xrdp

systemctl stop xrdp
systemctl stop xrdp-sesman

# Install Gnome Tweak Tool
apt install gnome-tweak-tool -y

# Configure the installed XRDP ini files.
# use vsock transport.
sed -i_orig -e 's/port=3389/port=vsock:\/\/-1:3389/g' /etc/xrdp/xrdp.ini
# use rdp security.
sed -i_orig -e 's/security_layer=negotiate/security_layer=rdp/g' /etc/xrdp/xrdp.ini
# remove encryption validation.
sed -i_orig -e 's/crypt_level=high/crypt_level=none/g' /etc/xrdp/xrdp.ini
# disable bitmap compression since its local its much faster
sed -i_orig -e 's/bitmap_compression=true/bitmap_compression=false/g' /etc/xrdp/xrdp.ini

# Add script to setup the ubuntu session properly
if [ ! -e /etc/xrdp/startpop.sh ]; then
cat >> /etc/xrdp/startpop.sh << EOF
#!/bin/sh
export GNOME_SHELL_SESSION_MODE=pop
export XDG_CURRENT_DESKTOP=pop:GNOME
exec /etc/xrdp/startwm.sh
EOF
chmod a+x /etc/xrdp/startpop.sh
fi

# use the script to setup the ubuntu session
sed -i_orig -e 's/startwm/startpop/g' /etc/xrdp/sesman.ini

# rename the redirected drives to 'shared-drives'
sed -i -e 's/FuseMountName=thinclient_drives/FuseMountName=shared-drives/g' /etc/xrdp/sesman.ini

# Changed the allowed_users
sed -i_orig -e 's/allowed_users=console/allowed_users=anybody/g' /etc/X11/Xwrapper.config

# Blacklist the vmw module
if [ ! -e /etc/modprobe.d/blacklist-vmw_vsock_vmci_transport.conf ]; then
  echo "blacklist-vmw_vsock_vmci_transport" > /etc/modprobe.d/blacklist-vmw_vsock_vmci_transport.conf
fi

# Ensure hv_sock gets loaded
if [ ! -e /etc/modules-load.d/hv_sock.conf ]; then
  echo "hv_sock" > /etc/modules-load.d/hv_sock.conf
fi

# Configure the policy xrdp session
cat > /etc/polkit-1/localauthority/50-local.d/45-allow-colord.pkla <<EOF
[Allow Colord all Users]
Identity=unix-user:*
Action=org.freedesktop.color-manager.create-device;org.freedesktop.color-manager.create-profile;org.freedesktop.color-manager.delete-device;org.freedesktop.color-manager.delete-profile;org.freedesktop.color-manager.modify-device;org.freedesktop.color-manager.modify-profile
ResultAny=no
ResultInactive=no
ResultActive=yes
EOF

cat >/etc/polkit-1/localauthority/50-local.d/46-allow-update-repo.pkla <<EOF
[Allow Package Management all Users]
Identity=unix-user:*
Action=org.freedesktop.packagekit.system-sources-refresh
ResultAny=yes
ResultInactive=yes
ResultActive=yes
EOF

# Enable Sound Redirection
# ------------------------------------------

# Step 1 - Enable Source Code Repository
codename=$(lsb_release -sc)
apt-add-repository -s -y 'deb http://archive.ubuntu.com/ubuntu/ '$codename' main restricted'
apt-add-repository -s -y 'deb http://archive.ubuntu.com/ubuntu/ '$codename' restricted universe main multiverse'
apt-add-repository -s -y 'deb http://archive.ubuntu.com/ubuntu/ '$codename'-updates restricted universe main multiverse'
apt-add-repository -s -y 'deb http://archive.ubuntu.com/ubuntu/ '$codename'-backports main restricted universe multiverse'
apt-add-repository -s -y 'deb http://archive.ubuntu.com/ubuntu/ '$codename'-security main restricted universe main multiverse'
apt-get update

# Step 2 - Install Some PreReqs
apt install git libpulse-dev autoconf m4 intltool build-essential dpkg-dev libtool libsndfile-dev libcap-dev -y libjson-c-dev
apt build-dep pulseaudio -y

# Step 3 -  Download pulseaudio source in /tmp directory - Do not forget to enable source repositories
cd /tmp
apt source pulseaudio

# Step 4 - Compile
pulsever=$(pulseaudio --version | awk '{print $2}')
cd /tmp/pulseaudio-$pulsever
sudo ./configure

# step 5 - Create xrdp sound modules
sudo git clone https://github.com/neutrinolabs/pulseaudio-module-xrdp.git
cd pulseaudio-module-xrdp
sudo ./bootstrap 
sudo ./configure PULSE_DIR="/tmp/pulseaudio-$pulsever"
sudo make

#Step 6 copy files to correct location (as defined in /etc/xrdp/pulse/default.pa)
cd /tmp/pulseaudio-$pulsever/pulseaudio-module-xrdp/src/.libs
sudo install -t "/var/lib/xrdp-pulseaudio-installer" -D -m 644 *.so
sudo install -t "/usr/lib/pulse-$pulsever/modules" -D -m 644 *.so
echo
# -----------------------------------------

# Fix SSL Minor Issue
if id -Gn xrdp | grep ssl-cert 
then 
/bin/echo -e "\e[1;32m   !--xrdp already member ssl-cert...Skipping ---!\e[0m" 
else
	sudo adduser xrdp ssl-cert 
fi

# Fixing env variables in XRDP
#Add this line to /etc/pam.d/xrdp-sesman if not present
if grep -Fxq "session required pam_env.so readenv=1 user_readenv=0" /etc/pam.d/xrdp-sesman 
   then
            echo "Env settings already set"
   else
		sudo sed -i '1 a session required pam_env.so readenv=1 user_readenv=0' /etc/pam.d/xrdp-sesman
fi

# reconfigure the service
systemctl daemon-reload
systemctl start xrdp

#
# End XRDP
###############################################################################

echo "Install is complete."
echo "Reboot your machine to begin using XRDP."
