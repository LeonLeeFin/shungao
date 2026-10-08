import unittest
from types import SimpleNamespace
from unittest.mock import patch
from pathlib import Path
import sys
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'engine'))
from device_input import open_input

class DeviceSelectionTests(unittest.TestCase):
    def run_selection(self,target):
        calls=[]
        class Stream:
            def __init__(self,device,**kwargs): self._ptr=device;calls.append(('open',device))
            def close(self):calls.append(('close',self._ptr))
        devices=[dict(name='同名输入',max_input_channels=1,hostapi=0,default_samplerate=48000),dict(name='同名输入',max_input_channels=1,hostapi=0,default_samplerate=48000)]
        sd=SimpleNamespace(_terminate=lambda:calls.append('refresh-close'),_initialize=lambda:calls.append('refresh-open'),query_devices=lambda:devices,query_hostapis=lambda i:dict(name='Core Audio'),_libname='test-lib',_ffi=SimpleNamespace(cast=lambda t,p:p),InputStream=Stream)
        def identify(ptr):return [101,202][int(ptr)]
        with patch('device_input.ctypes.CDLL',return_value=SimpleNamespace(PaMacCore_GetStreamInputDevice=identify)):
            if target==999:
                with self.assertRaisesRegex(RuntimeError,'未启动采集'):open_input(sd,dict(coreAudioID=target,deviceName='同名输入'),lambda *a:None)
                return calls,None
            stream,info,rate=open_input(sd,dict(coreAudioID=target,deviceName='同名输入'),lambda *a:None)
            return calls,stream
    def test_duplicate_names_verify_actual_coreaudio_id(self):
        calls,stream=self.run_selection(202)
        self.assertEqual(stream._ptr,1)
        self.assertIn(('close',0),calls)
        self.assertNotIn(('close',1),calls)
    def test_missing_id_closes_all_handles_without_starting_capture(self):
        calls,_=self.run_selection(999)
        self.assertIn(('close',0),calls);self.assertIn(('close',1),calls)
    def test_native_selection_does_not_use_saved_portaudio_index(self):
        calls,stream=self.run_selection(101)
        self.assertEqual(stream._ptr,0);self.assertEqual(calls[:2],['refresh-close','refresh-open'])

if __name__=='__main__':unittest.main()
