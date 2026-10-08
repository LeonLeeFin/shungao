import io
import json
import queue
import sys
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch
import numpy as np
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'engine'))
import worker


class WorkerControlTests(unittest.TestCase):
    def setUp(self):
        worker.commands = queue.Queue()
        worker.state.update(paused=True, epoch=0)

    def test_pause_immediately_invalidates_inflight_generation(self):
        messages = [{'type':'start','epoch':4,'paused':False},
                    {'type':'pause','epoch':5,'paused':True}]
        with patch('sys.stdin', io.StringIO(''.join(json.dumps(m)+'\n' for m in messages))):
            worker.reader()
        self.assertEqual(worker.state['epoch'], 5)
        self.assertTrue(worker.state['paused'])
        self.assertEqual(worker.commands.get()['type'], 'start')
        self.assertEqual(worker.commands.get()['type'], 'pause')

    def test_obsolete_start_never_opens_microphone(self):
        worker.state.update(paused=True, epoch=2)
        worker.commands.put({'type':'start','epoch':1,'paused':False})
        worker.commands.put({'type':'quit'})
        device = SimpleNamespace(query_devices=lambda *args: self.fail('stale start opened microphone'))
        with patch.object(worker,'load_model',return_value=object()), \
             patch.object(worker.threading.Thread,'start'), \
             patch.dict(sys.modules, {'sounddevice':device}), \
             patch.object(sys,'argv',['worker.py']):
            worker.main()

    def test_nonspeech_classification_does_not_move_prompt(self):
        for event, expected in [('Music',''),('Noise',''),('Speech','今天我们讨论利率')]:
            model=SimpleNamespace(generate=lambda *a, **k: SimpleNamespace(
                text=' 今天我们讨论利率 ',segments=[{'event':event}]))
            text,elapsed=worker.recognize(model,'sensevoice',np.ones(16000,dtype=np.float32))
            self.assertEqual(text,expected)
            self.assertGreaterEqual(elapsed,0)

    def simulate_stream(self, failure=None):
        calls=[]; events=[]; clock=[0.0]
        class Stream:
            def start(self):
                calls.append('start')
                if failure=='stall':clock[0]=4
            def stop(self):
                calls.append('stop')
                if failure=='stop':raise RuntimeError('device disconnected during stop')
            def close(self):calls.append('close')
        class Commands:
            def __init__(self):self.messages=iter([{'type':'start','epoch':1,'paused':False},{'type':'pause','epoch':2,'paused':True},{'type':'quit'}])
            def get(self,timeout):
                message=next(self.messages)
                if message['type']!='quit':worker.state.update(epoch=message['epoch'],paused=message['paused'])
                return message
        def query(*args):
            if failure=='device':raise RuntimeError('input device unavailable')
            return {'name':'Test input','default_samplerate':48000}
        device=SimpleNamespace(query_devices=query,InputStream=lambda **kw:Stream())
        worker.audio_queue=queue.Queue(maxsize=80)
        with patch.object(worker,'commands',Commands()), \
             patch.object(worker,'load_model',return_value=object()), \
             patch.object(worker.threading.Thread,'start'), \
             patch.object(worker.time,'monotonic',side_effect=lambda:clock[0]), \
             patch.object(worker,'emit',side_effect=lambda kind,**kw:events.append({'type':kind,**kw})), \
             patch.dict(sys.modules,{'sounddevice':device}), \
             patch.object(sys,'argv',['worker.py']):
            worker.main()
        return calls,events

    def test_pause_stops_and_closes_input_stream(self):
        calls,events=self.simulate_stream()
        self.assertEqual(calls,['start','stop','close'])
        self.assertTrue(worker.audio_queue.empty())
        self.assertTrue(any(e['type']=='paused' for e in events))

    def test_disconnected_stream_still_closes_after_stop_error(self):
        calls,events=self.simulate_stream('stop')
        self.assertEqual(calls,['start','stop','close'])
        self.assertTrue(any(e['type']=='paused' for e in events))

    def test_input_device_failure_has_actionable_error(self):
        calls,events=self.simulate_stream('device')
        self.assertEqual(calls,[])
        self.assertTrue(any(e['type']=='error' and '无法使用输入设备' in e['message'] for e in events))

    def test_stalled_input_is_released_and_reported(self):
        calls,events=self.simulate_stream('stall')
        self.assertEqual(calls,['start','stop','close'])
        self.assertTrue(any(e['type']=='error' and '重新选择麦克风' in e['message'] for e in events))

    def test_gate_command_updates_without_restarting_stream(self):
        calls=[];events=[]
        class Stream:
            def start(self):calls.append('start')
            def stop(self):calls.append('stop')
            def close(self):calls.append('close')
        class Commands:
            def __init__(self):self.items=iter([{'type':'start','epoch':1,'paused':False}, {'type':'gate','value':.012}, {'type':'pause','epoch':2,'paused':True}, {'type':'quit'}])
            def get(self,timeout):
                message=next(self.items)
                if 'epoch' in message:worker.state.update(epoch=message['epoch'],paused=message['paused'])
                if message['type']=='pause':
                    self_test.assertTrue(any(e['type']=='gate' and e['value']==.012 for e in events))
                    self_test.assertEqual(calls,['start'])
                return message
        self_test=self
        device=SimpleNamespace(query_devices=lambda *args:{'name':'Fake input','default_samplerate':48000},InputStream=lambda **kw:Stream())
        worker.audio_queue=queue.Queue(maxsize=80)
        with patch.object(worker,'commands',Commands()), patch.object(worker,'load_model',return_value=object()), patch.object(worker.threading.Thread,'start'), patch.object(worker,'emit',side_effect=lambda kind,**kw:events.append({'type':kind,**kw})), patch.dict(sys.modules,{'sounddevice':device}), patch.object(sys,'argv',['worker.py']):worker.main()
        self.assertEqual(calls,['start','stop','close'])

    def test_gate_rejects_nonfinite_and_clamps_valid_values(self):
        self.assertEqual(worker.clamp_gate(.1),.03)
        self.assertEqual(worker.clamp_gate(0),.001)
        for value in [float('nan'),float('inf'),'invalid']:
            with self.assertRaises((ValueError,TypeError)):worker.clamp_gate(value)


if __name__ == '__main__':
    unittest.main(verbosity=2)
