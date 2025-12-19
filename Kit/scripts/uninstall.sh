#! /bin/sh

sudo launchctl unload /Library/LaunchDaemons/com.aravhawk.lite-stats.SMC.Helper.plist
sudo rm /Library/LaunchDaemons/com.aravhawk.lite-stats.SMC.Helper.plist
sudo rm /Library/PrivilegedHelperTools/com.aravhawk.lite-stats.SMC.Helper
sudo rm "$HOME/Library/Application Support/Lite Stats"
