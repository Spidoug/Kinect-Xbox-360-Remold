Name:           kinect360-remold
Version:        1.0.0
Release:        1%{?dist}
Summary:        Kinect Xbox 360 Remold native Linux runtime
License:        LicenseRef-Kinect-Xbox-360-Remold
BuildArch:      x86_64
Requires:       libusb1, alsa-lib, libjpeg-turbo, systemd, udev, kmod, curl, p7zip
Recommends:     v4l2loopback

%description
Direct libusb RGB/IR/depth, four-channel audio, motor/status broker, V4L2
virtual camera and authenticated IP-camera runtime for Kinect 1414.

%prep
# Build this spec from the repository root; no source unpack is required.

%install
rm -rf %{buildroot}
install -d %{buildroot}%{_bindir} %{buildroot}%{_libexecdir}/kinect360-remold \
  %{buildroot}%{_unitdir} %{buildroot}%{_udevrulesdir} %{buildroot}%{_sysconfdir}/modprobe.d \
  %{buildroot}%{_sysconfdir}/modules-load.d %{buildroot}%{_sysconfdir}/kinect360-remold \
  %{buildroot}%{_datadir}/kinect360-remold
install -m0755 drivers/linux/binaries/x86_64/bin/kinect360-remoldctl %{buildroot}%{_bindir}/
install -m0755 drivers/linux/binaries/x86_64/libexec/kinect360-remold/* %{buildroot}%{_libexecdir}/kinect360-remold/
install -m0644 drivers/linux/source/systemd/* %{buildroot}%{_unitdir}/
install -m0644 drivers/linux/source/udev/60-kinect360-remold.rules %{buildroot}%{_udevrulesdir}/
install -m0644 drivers/linux/source/modprobe/kinect360-remold-v4l2.conf %{buildroot}%{_sysconfdir}/modprobe.d/
install -m0644 drivers/linux/source/modules-load/kinect360-remold.conf %{buildroot}%{_sysconfdir}/modules-load.d/
install -m0644 drivers/linux/source/config/remold.conf %{buildroot}%{_sysconfdir}/kinect360-remold/remold.conf
install -m0755 drivers/linux/source/scripts/fetch-uac-firmware.sh %{buildroot}%{_datadir}/kinect360-remold/

%post
%systemd_post kinect360-remold.target
/usr/bin/udevadm control --reload-rules >/dev/null 2>&1 || :
/usr/sbin/modprobe v4l2loopback >/dev/null 2>&1 || :
if [ ! -f %{_datadir}/kinect360-remold/UACFirmware ]; then
  %{_datadir}/kinect360-remold/fetch-uac-firmware.sh %{_datadir}/kinect360-remold/UACFirmware || :
fi

%preun
%systemd_preun kinect360-remold.target

%postun
%systemd_postun_with_restart kinect360-remold.target
/usr/bin/udevadm control --reload-rules >/dev/null 2>&1 || :

%files
%config(noreplace) %{_sysconfdir}/kinect360-remold/remold.conf
%{_bindir}/kinect360-remoldctl
%{_libexecdir}/kinect360-remold/*
%{_unitdir}/kinect360-remold*
%{_udevrulesdir}/60-kinect360-remold.rules
%{_sysconfdir}/modprobe.d/kinect360-remold-v4l2.conf
%{_sysconfdir}/modules-load.d/kinect360-remold.conf
%{_datadir}/kinect360-remold/fetch-uac-firmware.sh

%changelog
* Sat Aug 22 2026 Kinect Xbox 360 Remold Project - 1.0.0-2
- Native GUI-installable package recipe and buffered scanner transport.
