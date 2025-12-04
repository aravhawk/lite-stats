#! /bin/sh

sudo launchctl unload /Library/LaunchDaemons/eu.exelban.LiteStats.SMC.Helper.plist
sudo rm /Library/LaunchDaemons/eu.exelban.LiteStats.SMC.Helper.plist
sudo rm /Library/PrivilegedHelperTools/eu.exelban.LiteStats.SMC.Helper
sudo rm "$HOME/Library/Application Support/Lite Stats"
