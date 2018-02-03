# A Simple HTTP Site Monitor

Simply list the URLs you'd like to monitor (along with any custom options) in a YAML file. If any site goes down (threshold configured in `settings.yml`) or a site starts "flapping" (again, flap threshold defined in `settings.yml`), you'll get an alert via Telegram.

# Getting Started

Create a [Telegram](https://telegram.org/) account. A [Telegram group](https://telegram.org/faq#q-how-do-i-create-a-group). A [Telegram bot](https://core.telegram.org/bots#creating-a-new-bot). Add your bot to the Telegram group you just created.
Add users to this group if they should receive alerts for a site going offline.

# Installation

## RHEL/CentOS 7.X

```
yum -y install ruby
mkdir -p /opt/site-check/
cd /opt/site-check/
git clone git@github.com:AndrewPaglusch/Simple-HTTP-Site-Monitor.git
cp sites.yml.example sites.yml
#edit your sites.yml file and add some sites you want to monitor
```

# Daemonize

## Make the Service

Create this file `/etc/systemd/system/site-check.service`. 

Insert the following:

```
[Unit]
Description=Simple HTTP Site Monitor
After=network.target

[Service]
WorkingDirectory=/opt/site-check
Type=simple
ExecStart=/usr/bin/ruby /opt/site-check/run.rb
Restart=always
RestartSec=15

[Install]
WantedBy=multi-user.target
```

## Enable & Start

```
systemctl enable site-check.service
systemctl start site-check.service
systemctl status site-check.service
```

# Screenshot

![Picture of Simple HTTP Site Monitor](https://i.imgur.com/GVJkubv.png)
