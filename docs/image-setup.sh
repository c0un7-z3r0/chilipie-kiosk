#!/bin/bash

MOUNTED_BOOT_VOLUME="boot" # i.e. under which name is the SD card mounted under /Volumes on macOS
BOOT_CMDLINE_TXT="/Volumes/$MOUNTED_BOOT_VOLUME/cmdline.txt"
BOOT_CONFIG_TXT="/Volumes/$MOUNTED_BOOT_VOLUME/config.txt"
SD_SIZE_REAL=2500 # this is in MB
SD_SIZE_SAFE=2800 # this is in MB
SD_SIZE_ZERO=3200 # this is in MB
PUBKEY="$(cat ~/.ssh/id_rsa.pub)"
KEYBOARD="de" # or e.g. "fi" for Finnish
TIMEZONE="Europe/Berlin" # or e.g. "Europe/Helsinki"; see https://en.wikipedia.org/wiki/List_of_tz_database_time_zones

function ask() {
    # This is a general-purpose function to ask Yes/No questions in Bash, either
    # with or without a default answer. It keeps repeating the question until it
    # gets a valid answer.
    # https://gist.github.com/davejamesmiller/1965569
    local prompt default reply

    if [ "${2:-}" = "Y" ]; then
        prompt="Y/n"
        default=Y
    elif [ "${2:-}" = "N" ]; then
        prompt="y/N"
        default=N
    else
        prompt="y/n"
        default=
    fi

    while true; do

        # Ask the question (not using "read -p" as it uses stderr not stdout)
        echo -n "🤔 $1 [$prompt] "

        # Read the answer (use /dev/tty in case stdin is redirected from somewhere else)
        read reply </dev/tty

        # Default?
        if [ -z "$reply" ]; then
            reply=$default
        fi

        # Check if the reply is valid
        case "$reply" in
            Y*|y*) return 0 ;;
            N*|n*) return 1 ;;
        esac

    done
}

function info {
  echo -e "ℹ️  $1"
}
function warn {
  echo -e "\n⚠️  $1"
}
function working {
  echo -e "\n🚧  $1"
}
function question {
  echo -e "\n🔴  $1"
}
function ssh {
  /usr/bin/ssh -o LogLevel=ERROR -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 "pi@$IP" "$1"
}
function scp {
  /usr/bin/scp -o LogLevel=ERROR -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$@" "pi@$IP:/home/pi"
}

question "Name of the Dashboard (e.g. \"chilipie-kiosk\") being built (used as hostname):"
read DASHBOARD_NAME

question "Enter version (e.g. \"1.2.3\") being built:"
read TAG

working "Updating version file"
echo -e "$DASHBOARD_NAME-$TAG\n\nhttps://github.com/c0un7-z3r0/chilipie-kiosk" > ../home/.chilipie-kiosk-version

working "Generating first-boot.html"
if [ ! -d "node_modules" ]; then
  npm install markdown-styles@3.1.10 html-inline@1.2.0
fi
rm -rf md-input md-output
mkdir md-input md-output
sed "s/%%DASBOARD_NAME%%/${DASHBOARD_NAME}/g" ../docs/first-boot.md > md-input/first-boot.md
./node_modules/.bin/generate-md --layout github --input md-input/ --output md-output/
./node_modules/.bin/html-inline -i md-output/first-boot.html > ../home/first-boot.html
rm -rf md-input md-output

question "Mount the SD card (press enter when ready)"
read

working "Figuring out SD card device"
diskutil list
DISK="$(diskutil list | grep /dev/ | grep external | grep physical | cut -d ' ' -f 1 | head -n 1)"

question "Based on the above, SD card determined to be \"$DISK\" (should be e.g. \"/dev/disk2\"), press enter to continue"
read

working "Safely unmounting the card"
diskutil unmountDisk "$DISK"

working "Writing the card full of zeros (for security and compressibility reasons)"
info "This may take a long time"
info "You may be prompted for your password by sudo"
sudo dd bs=1m count="$SD_SIZE_ZERO" if=/dev/zero of="$DISK"

question "Prepare baseline Raspbian:"
echo "* Download Raspbian Lite (https://www.raspberrypi.org/downloads/raspbian/)"
echo "* Download Etcher (https://www.balena.io/etcher/)"
echo "* Flash Raspbian Lite with Etcher"
echo "* Eject the SD card"
echo "* Mount the card back"
echo "(press enter when ready)"
read

working "Backing up original boot files"
cp -v "$BOOT_CMDLINE_TXT" "$BOOT_CMDLINE_TXT.backup"
cp -v "$BOOT_CONFIG_TXT" "$BOOT_CONFIG_TXT.backup"

working "Disabling automatic root filesystem expansion"
info "Updating: $BOOT_CMDLINE_TXT"
cat "$BOOT_CMDLINE_TXT" | sed "s#init=/usr/lib/raspi-config/init_resize.sh##" > temp
mv temp "$BOOT_CMDLINE_TXT"

working "Enabling SSH for first boot"
# https://www.raspberrypi.org/documentation/remote-access/ssh/
touch "/Volumes/$MOUNTED_BOOT_VOLUME/ssh"

if ask "Do you want to configure WiFi?"; then
    question "Enter WiFi SSID (a.k.a. \"WiFi Name\")"
    read WIFI_SSID
    question "Enter WiFi Password (e.g. \"password123\")"
    read WIFI_PASSWORD

    working "Copy wpa_supplicant.conf."
    cp "../docs/wpa_supplicant.conf" "/Volumes/$MOUNTED_BOOT_VOLUME/wpa_supplicant.conf"
    sed -i "" "s/%%WIFI_SSID%%/${WIFI_SSID}/g" /Volumes/$MOUNTED_BOOT_VOLUME/wpa_supplicant.conf
    sed -i "" "s/%%WIFI_PASSWORD%%/${WIFI_PASSWORD}/g" /Volumes/$MOUNTED_BOOT_VOLUME/wpa_supplicant.conf

else
    warn "Skipping WiFi setup."
fi

working "Safely unmounting the card"
diskutil unmountDisk "$DISK"

question "Do initial Pi setup:"
echo "* Eject the card"
echo "* Connect your Pi to Ethernet"
echo "* Boot the Pi from your card"
echo "* Make note of the \"My IP address is\" message at the end of boot"
question "Enter the IP address:"
read IP

working "Installing temporary SSH pubkey"
info "Password hint: \"raspberry\""
ssh "mkdir .ssh && echo '$PUBKEY' > .ssh/authorized_keys"

working "Figuring out partition start"
ssh "echo -e 'p\nq\n' | sudo fdisk /dev/mmcblk0 | grep /dev/mmcblk0p2 | tr -s ' ' | cut -d ' ' -f 2" > temp
START="$(cat temp)"
rm temp

question "Partition start determined to be \"$START\" (should be e.g. \"98304\"), press enter to continue"
read

working "Resizing the root partition on the Pi"
ssh "echo -e 'd\n2\nn\np\n2\n$START\n+${SD_SIZE_REAL}M\ny\nw\n' | sudo fdisk /dev/mmcblk0"

working "Setting hostname"
# We want to do this right before reboot, so we don't get a lot of unnecessary complaints about "sudo: unable to resolve host $DASHBOARD_NAME" (https://askubuntu.com/a/59517)
ssh "sudo hostnamectl set-hostname $DASHBOARD_NAME"
ssh "sudo sed -i 's/raspberrypi/$DASHBOARD_NAME/g' /etc/hosts"

working "Rebooting the Pi"
ssh "sudo reboot"

working "Waiting for host to come back up..."
until ssh "echo OK"
do
  sleep 1
done

working "Finishing the root partition resize"
ssh "df -h . && sudo resize2fs /dev/mmcblk0p2 && df -h ."

working "Enabling auto-login to CLI"
# From: https://github.com/RPi-Distro/raspi-config/blob/985548d7ca00cab11eccbb734b63750761c1f08a/raspi-config#L955
SUDO_USER=pi
ssh "sudo systemctl set-default multi-user.target"
ssh "sudo sed /etc/systemd/system/autologin@.service -i -e \"s#^ExecStart=-/sbin/agetty --autologin [^[:space:]]*#ExecStart=-/sbin/agetty --autologin $SUDO_USER#\""
# Set auto-login for TTY's 1-3
ssh "sudo ln -fs /etc/systemd/system/autologin@.service /etc/systemd/system/getty.target.wants/getty@tty1.service"
ssh "sudo ln -fs /etc/systemd/system/autologin@.service /etc/systemd/system/getty.target.wants/getty@tty2.service"
ssh "sudo ln -fs /etc/systemd/system/autologin@.service /etc/systemd/system/getty.target.wants/getty@tty3.service"

working "Setting timezone"
ssh "(echo '$TIMEZONE' | sudo tee /etc/timezone) && sudo dpkg-reconfigure --frontend noninteractive tzdata"

working "Setting keyboard layout"
ssh "(echo -e 'XKBMODEL="pc105"\nXKBLAYOUT="$KEYBOARD"\nXKBVARIANT=""\nXKBOPTIONS=""\nBACKSPACE="guess"\n' | sudo tee /etc/default/keyboard) && sudo dpkg-reconfigure --frontend noninteractive keyboard-configuration"

working "Shortening message-of-the-day for logins"
ssh "sudo rm /etc/profile.d/sshpwd.sh"
ssh "echo | sudo tee /etc/motd"

working "Installing packages"
ssh "sudo apt-get update && sudo apt-get install -y vim matchbox-window-manager unclutter mailutils nitrogen jq chromium-browser xserver-xorg xinit rpd-plym-splash xdotool"
# We install mailutils just so that you can check "mail" for cronjob output

working "Setting home directory default content"
ssh "rm -rfv /home/pi/*"
scp $(find ../home -type file)

working "Setting splash screen background"
ssh "sudo rm /usr/share/plymouth/themes/pix/splash.png && sudo ln -s /home/pi/background.png /usr/share/plymouth/themes/pix/splash.png"

working "Installing default crontab"
ssh "crontab /home/pi/crontab.example"

working "Rebooting the Pi"
ssh "sudo reboot"

question "Once the Pi has rebooted into Chromium:"
echo "* Tell Chromium we don't want to sign in"
echo "* Configure Chromium to start \"where you left off\""
echo "* Navigate to \"file:///home/pi/first-boot.html\""
echo "(press enter when ready)"
read

working "Figuring out software versions"
ssh "hostnamectl | grep 'Operating System:' | tr -s ' ' | cut -d ' ' -f 4-" > temp
VERSION_LINUX="$(cat temp)"
ssh "hostnamectl | grep 'Kernel:' | tr -s ' ' | cut -d ' ' -f 3-4" > temp
VERSION_KERNEL="$(cat temp)"
ssh "chromium-browser --version | cut -d ' ' -f 1-2" > temp
VERSION_CHROMIUM="$(cat temp)"
rm temp

working "Removing temporary SSH pubkey, disabling SSH & shutting down"
ssh "(echo > .ssh/authorized_keys) && sudo systemctl disable ssh && sudo shutdown -h now"

question "Eject the SD card from the Pi, and mount it back to this computer (press enter when ready)"
read

working "Figuring out SD card device"
# We do this again now just to be safe
diskutil list
DISK="$(diskutil list | grep /dev/ | grep external | grep physical | cut -d ' ' -f 1 | head -n 1)"

question "Based on the above, SD card determined to be \"$DISK\" (should be e.g. \"/dev/disk2\"), press enter to continue"
read

working "Making boot quieter (part 1)" # https://scribles.net/customizing-boot-up-screen-on-raspberry-pi/
info "Updating: $BOOT_CONFIG_TXT"
sed -i "" "s/#disable_overscan=1/disable_overscan=1/g" "$BOOT_CONFIG_TXT"
echo -e "\ndisable_splash=1" >> "$BOOT_CONFIG_TXT"

working "Making boot quieter (part 2)" # https://scribles.net/customizing-boot-up-screen-on-raspberry-pi/
info "You may want to revert these changes if you ever need to debug the startup process"
info "Updating: $BOOT_CMDLINE_TXT"
cat "$BOOT_CMDLINE_TXT" \
  | sed 's/console=tty1/console=tty3/' \
  | sed 's/$/ splash plymouth.ignore-serial-consoles logo.nologo vt.global_cursor_default=0/' \
  > temp
mv temp "$BOOT_CMDLINE_TXT"

working "Safely unmounting the card"
diskutil unmountDisk "$DISK"

working "Dumping the image from the card"
cd ..
info "This may take a long time"
info "You may be prompted for your password by sudo"
sudo dd bs=1m count="$SD_SIZE_SAFE" if="$DISK" of="$DASHBOARD_NAME-$TAG.img"

working "Compressing image"
COPYFILE_DISABLE=1 tar -zcvf $DASHBOARD_NAME-$TAG.img.tar.gz $DASHBOARD_NAME-$TAG.img

working "Listing image sizes"
du -hs $DASHBOARD_NAME-$TAG.img*

working "Calculating image hashes"
openssl sha1 $DASHBOARD_NAME-$TAG.img*

working "Software versions are:"
info "* Linux: \`$VERSION_LINUX\`"
info "* Kernel: \`$VERSION_KERNEL\`"
info "* Chromium: \`$VERSION_CHROMIUM\`"
