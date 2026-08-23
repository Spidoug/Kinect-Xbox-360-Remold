#!/usr/bin/env python3
import pathlib, subprocess, sys, tempfile
root=pathlib.Path(__file__).resolve().parents[1]
cc='gcc'
out=pathlib.Path(tempfile.gettempdir())/'remold_acoustic_scan_test'
cmd=[cc,'-std=c11','-O2','-Wall','-Wextra','-Werror',
     '-I'+str(root/'include'),'-I'+str(root/'dsp'),
     str(root/'dsp/remold_fft.c'),str(root/'dsp/remold_scan.c'),str(root/'dsp/remold_echo.c'),
     str(root/'tests/test_scan.c'),'-lm','-o',str(out)]
print(' '.join(cmd))
subprocess.check_call(cmd)
subprocess.check_call([str(out)])
