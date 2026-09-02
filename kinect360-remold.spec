Name:           kinect360-remold
Version:        1.0
Release:        1%{?dist}
Summary:        Kinect Xbox 360 Remold native Linux runtime
License:        LicenseRef-Kinect-Xbox-360-Remold
URL:            https://github.com/
Source0:        %{name}-%{version}.tar.gz
BuildArch:      x86_64

BuildRequires:  gcc-c++
BuildRequires:  cmake
BuildRequires:  pkgconfig(libusb-1.0)
BuildRequires:  pkgconfig(alsa)
BuildRequires:  libjpeg-turbo-devel
BuildRequires:  systemd-rpm-macros

Requires:       libusb1
Requires:       alsa-lib
Requires:       libjpeg-turbo
Requires:       systemd
Requires:       udev
Requires:       kmod
Requires:       curl
Requires:       p7zip
Requires:       v4l2loopback >= 0.15.0

%description
Kinect Xbox 360 Remold V1 user-space runtime: direct libusb RGB/RGB-HQ/IR/Depth,
four-channel audio, motor/status broker, V4L2 virtual camera and authenticated
IP-camera service for Kinect 1414.

%prep
%setup -q

%build
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release -DREMOLD_BUILD_HARDWARE=ON
cmake --build build --parallel %{?_smp_build_ncpus}

%install
rm -rf %{buildroot}
DESTDIR=%{buildroot} cmake --install build --prefix %{_prefix}
install -d %{buildroot}%{_unitdir} %{buildroot}%{_udevrulesdir} \
  %{buildroot}%{_sysconfdir}/modprobe.d %{buildroot}%{_sysconfdir}/modules-load.d \
  %{buildroot}%{_sysconfdir}/kinect360-remold %{buildroot}%{_datadir}/kinect360-remold
install -m0644 systemd/* %{buildroot}%{_unitdir}/
install -m0644 udev/60-kinect360-remold.rules %{buildroot}%{_udevrulesdir}/
install -m0644 modprobe/kinect360-remold-v4l2.conf %{buildroot}%{_sysconfdir}/modprobe.d/
install -m0644 modules-load/kinect360-remold.conf %{buildroot}%{_sysconfdir}/modules-load.d/
install -m0644 config/remold.conf %{buildroot}%{_sysconfdir}/kinect360-remold/remold.conf
install -m0755 scripts/fetch-uac-firmware.sh %{buildroot}%{_datadir}/kinect360-remold/

%post
/usr/bin/systemctl daemon-reload >/dev/null 2>&1 || :
/usr/bin/systemctl disable kinect360-remold.target >/dev/null 2>&1 || :
/usr/bin/udevadm control --reload-rules >/dev/null 2>&1 || :
/usr/bin/udevadm trigger --subsystem-match=usb >/dev/null 2>&1 || :
/usr/sbin/modprobe v4l2loopback >/dev/null 2>&1 || :
if [ ! -f %{_datadir}/kinect360-remold/UACFirmware ]; then
  %{_datadir}/kinect360-remold/fetch-uac-firmware.sh %{_datadir}/kinect360-remold/UACFirmware || :
fi
KINECT_PRESENT=0
for DEV in /sys/bus/usb/devices/*; do
  [ -r "$DEV/idVendor" ] && [ -r "$DEV/idProduct" ] || continue
  [ "$(cat "$DEV/idVendor")" = "045e" ] || continue
  case "$(cat "$DEV/idProduct")" in 02b0|02c2|02ae|02ad|02bb) KINECT_PRESENT=1; break;; esac
done
if [ "$KINECT_PRESENT" = 1 ]; then /usr/bin/systemctl start kinect360-remold.target >/dev/null 2>&1 || :; fi

%preun
if [ "$1" -eq 0 ]; then /usr/bin/systemctl stop kinect360-remold.target >/dev/null 2>&1 || :; fi

%postun
/usr/bin/systemctl daemon-reload >/dev/null 2>&1 || :
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
* Tue Aug 25 2026 Kinect Xbox 360 Remold Project - 1.0-1
- V1 source build with multi-Kinect transport, RGB-HQ and current service policy.
