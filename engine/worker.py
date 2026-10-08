"""Private stdio worker. Local MLX weights only. Never exposes a server."""
import os
os.environ['HF_HUB_OFFLINE'] = '1'
os.environ['TRANSFORMERS_OFFLINE'] = '1'
os.environ['HF_HUB_DISABLE_TELEMETRY'] = '1'
os.environ['TOKENIZERS_PARALLELISM'] = 'false'
import sys
import json
import time
import threading
import queue
import argparse
from pathlib import Path
import numpy as np
from matcher import Matcher
from audio_input import read_audio, prepare_audio
from device_input import open_input

# The application passes a verified shared model directory, independent of its runtime.
MODEL_DIRECTORY = os.environ.get('SHUNGAO_MODEL_DIR')
commands = queue.Queue()
audio_queue = queue.Queue(maxsize=64)
guard = threading.Lock()
state = {'paused': True, 'epoch': 0, 'last_block': 0.0,
         'level': 0.0, 'last_speech': 0.0, 'speech_start': 0.0, 'telemetry_running': False}
out_lock = threading.Lock()


def emit(kind, **kw):
    with out_lock:
        print(json.dumps(dict(type=kind, **kw), ensure_ascii=False), flush=True)


def reader():
    for line in sys.stdin:
        try:
            cmd = json.loads(line)
            if cmd.get('type') in ('pause', 'start', 'locate', 'script', 'stop'):
                with guard:
                    state['epoch'] = cmd.get('epoch', state['epoch']+1)
                    state['paused'] = cmd.get('paused', cmd['type'] != 'start')
            commands.put(cmd)
        except Exception as e:
            emit('error', message='控制指令无效：'+str(e))
    commands.put({'type': 'quit'})


def telemetry():
    # The callback never waits on JSON / stdout or model generation. This
    # independent path reports fresh silence even while inference is busy.
    previous = None
    while state['telemetry_running']:
        if not state['paused']:
            epoch = state['epoch']
            speaking = time.monotonic()-state['last_speech'] < .12
            current = (epoch, speaking)
            if current != previous:
                emit('voice_activity', speaking=speaking, epoch=epoch, speech_started=state['speech_start'])
                previous = current
            emit('level', value=state['level'], epoch=epoch)
        time.sleep(.05)


def load_model(name, compute='auto'):
    import mlx.core as mx
    if compute == 'cpu' or (compute == 'auto' and not mx.metal.is_available()):
        mx.set_default_device(mx.cpu)
    from mlx_audio.stt.utils import load_model as load
    if not MODEL_DIRECTORY:
        raise RuntimeError('请通过应用模型管理器选择并验证模型目录')
    path = Path(MODEL_DIRECTORY)
    if not (path / 'model.safetensors').exists():
        raise RuntimeError('本地模型缺失：'+str(path))
    # Reject model-supplied executable code, including tokenizer auto_map.
    if list(path.glob('*.py')):
        raise RuntimeError('模型目录包含未批准的 Python 代码')
    tok = path / 'tokenizer_config.json'
    if tok.exists() and json.loads(tok.read_text()).get('auto_map'):
        raise RuntimeError('拒绝模型自定义 tokenizer 代码')
    start = time.monotonic()
    model = load(path)
    # Compile the first Metal kernels while loading, before opening input.
    # The silent warm-up is never sent to the matcher or the UI.
    model.generate(np.zeros(8000, dtype=np.float32),
                   language='zh' if name == 'sensevoice' else 'Chinese',
                   max_tokens=8, verbose=False)
    emit('ready', model=name, seconds=round(time.monotonic()-start, 3), compute=str(mx.default_device()))
    return model


def recognize(model, name, samples, on_partial=None, cancelled=None):
    start = time.monotonic()
    budget = min(80, max(16, int(len(samples)/16000*14)+12))
    if name == 'qwen' and on_partial is not None:
        # Decode accumulated tokens, not isolated BPE pieces (which can split
        # Chinese UTF-8). These are actual ASR tokens, never predicted timing.
        tokens, previous, published = [], '', start
        for token, _ in model.stream_generate(samples, language='Chinese',
                                               max_tokens=budget, verbose=False):
            if cancelled and cancelled():
                return '', round(time.monotonic()-start, 3)
            tokens.append(int(token))
            raw = model._tokenizer.decode(tokens, skip_special_tokens=True)
            _, text = model.extract_language(raw)
            text = text.strip()
            now = time.monotonic()
            if text != previous and '\ufffd' not in text and now-published >= .06:
                on_partial(text, round(now-start, 3))
                previous, published = text, now
        _, text = model.extract_language(model._tokenizer.decode(tokens, skip_special_tokens=True))
        return text.strip(), round(time.monotonic()-start, 3)
    result = model.generate(samples, language='zh' if name == 'sensevoice' else 'Chinese', max_tokens=budget, verbose=False)
    text = result.text.strip()
    segments = getattr(result, 'segments', []) or []
    if name == 'sensevoice' and segments and segments[0].get('event') != 'Speech':
        text = ''
    return text, round(time.monotonic()-start, 3)


def clamp_gate(value):
    number = float(value)
    if not np.isfinite(number):
        raise ValueError('静音门限无效')
    return min(.03, max(.001, number))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--model', choices=['sensevoice', 'qwen'], default='sensevoice')
    parser.add_argument('--file')
    parser.add_argument('--script')
    parser.add_argument('--compute', choices=['auto', 'cpu'], default='auto')
    parser.add_argument('--devices', action='store_true')
    args = parser.parse_args()
    if args.devices:
        import sounddevice as sd
        emit('devices', devices=[dict(id=i, name=d['name'], channels=d['max_input_channels'], rate=d['default_samplerate']) for i,d in enumerate(sd.query_devices()) if d['max_input_channels']>0])
        return
    samples = read_audio(args.file) if args.file else None
    model = load_model(args.model, args.compute)
    matcher = Matcher(Path(args.script).read_text() if args.script else '')
    if args.file:
        for n in sorted(set(min(n, len(samples)) for n in (int(2.4*16000), int(4.2*16000), len(samples)))):
            text, elapsed = recognize(model, args.model, samples[:n])
            emit('transcript', text=text, seconds=elapsed, duration=min(n,len(samples))/16000, **matcher.feed(text))
        return
    import sounddevice as sd
    threading.Thread(target=reader, daemon=True).start()
    state['telemetry_running'] = True
    threading.Thread(target=telemetry, daemon=True).start()
    stream = None
    chunks, speech_samples, silent_samples = [], 0, 0
    local_epoch = -1
    gate = .006

    def reset_audio():
        nonlocal chunks, speech_samples, silent_samples
        chunks, speech_samples, silent_samples = [], 0, 0
        state['level'] = 0.0
        state['last_speech'] = 0.0
        while True:
            try: audio_queue.get_nowait()
            except queue.Empty: break

    def stop():
        nonlocal stream
        active = stream
        stream = None
        if active is not None:
            # A disconnected device may throw on stop; still close its handle.
            try: active.stop()
            except Exception: pass
            try: active.close()
            except Exception: pass
        reset_audio()

    def callback(data, frames, timing, status):
        state['last_block'] = time.monotonic()
        if status:
            emit('warning', message='音频输入溢出，请降低其他程序负载')
        if state['paused']:
            return
        state['level'] = float(np.sqrt(np.mean(data[:,0]*data[:,0])))
        if state['level'] >= gate:
            if state['last_block']-state['last_speech'] >= .12:
                state['speech_start'] = state['last_block']
            state['last_speech'] = state['last_block']
        # Tag every block so a manual re-anchor cannot reuse older queued audio.
        packet = (state['epoch'], time.monotonic(), data[:, 0].copy())
        try: audio_queue.put_nowait(packet)
        except queue.Full:
            try:
                audio_queue.get_nowait(); audio_queue.put_nowait(packet)
            except (queue.Empty, queue.Full): pass

    while True:
        try:
            cmd = commands.get(timeout=.02)
            kind = cmd.get('type')
            if kind == 'quit': state['telemetry_running']=False; stop(); break
            if kind == 'start' and cmd.get('epoch', state['epoch']) != state['epoch']:
                continue
            if kind == 'script': matcher.set_script(cmd.get('text','')); matcher.locate(cmd.get('offset',0)); reset_audio()
            elif kind == 'gate':
                gate = clamp_gate(cmd.get('value', .006))
                emit('gate', value=gate)
            elif kind == 'locate': matcher.locate(cmd.get('offset',0)); reset_audio()
            elif kind in ('pause','stop'): stop(); emit('paused', epoch=state['epoch'])
            elif kind == 'devices':
                emit('devices', devices=[dict(id=i, name=d['name'], channels=d['max_input_channels']) for i,d in enumerate(sd.query_devices()) if d['max_input_channels']>0])
            elif kind == 'start':
                stop()
                gate = clamp_gate(cmd.get('gate',.006))
                stream, info, rate = open_input(sd, cmd, callback)
                state['last_block'] = time.monotonic()
                stream.start()
                emit('listening', device=info['name'], epoch=state['epoch'])
        except queue.Empty:
            pass
        except Exception as e:
            state['paused'] = True
            stop()
            emit('error', message='无法使用输入设备：'+str(e))
        if state['epoch'] != local_epoch:
            local_epoch = state['epoch']; reset_audio()
        if state['paused'] or stream is None:
            continue
        if time.monotonic()-state['last_block'] > 3:
            state['paused'] = True; stop()
            emit('error', message='输入设备停止送入音频，请重新选择麦克风后继续')
            continue
        # Drain callback blocks together. There is only one inference in flight,
        # and no FIFO of obsolete recognition windows to fall behind live input.
        packets = []
        while True:
            try: packets.append(audio_queue.get_nowait())
            except queue.Empty: break
        if not packets: continue
        capture_end = None
        new_speech = False
        for packet_epoch, captured, data in packets:
            if packet_epoch != local_epoch: continue
            capture_end = captured
            rms = float(np.sqrt(np.mean(data*data)))
            voiced = rms >= gate
            new_speech = new_speech or voiced
            if voiced:
                speech_samples += len(data); silent_samples = 0
            else:
                silent_samples += len(data)
            if speech_samples:
                chunks.append((data, voiced))
        if capture_end is None: continue
        # A bounded acoustic window gives current context without increasing
        # encode/decode cost throughout a long sentence.
        limit = int(rate*3.2)
        total = sum(len(c) for c, _ in chunks)
        while total > limit and chunks:
            data, voiced = chunks[0]
            remove = min(len(data), total-limit)
            if voiced: speech_samples -= remove
            if remove == len(data): chunks.pop(0)
            else: chunks[0] = (data[remove:], voiced)
            total -= remove
        now = time.monotonic()
        if speech_samples == 0: continue
        duration = total/rate
        final = silent_samples/rate >= .22
        # Continue as soon as new speech is available after inference completes.
        # The actual model throughput determines cadence. Quiet input only
        # causes one final flush, then the acoustic buffer is cleared.
        if duration < .5 or (not new_speech and not final): continue
        if speech_samples/rate < .16:
            if final: chunks, speech_samples, silent_samples = [], 0, 0
            continue
        samples = prepare_audio(np.concatenate([c for c, _ in chunks]), rate)
        snapshot_epoch = state['epoch']
        def publish(text, elapsed, partial=False):
            if snapshot_epoch != state['epoch'] or state['paused']: return
            match_started = time.monotonic()
            alignment = matcher.feed(text, final=final and not partial, partial=partial)
            match_seconds = time.monotonic() - match_started
            emit('transcript', text=text, seconds=elapsed, epoch=snapshot_epoch,
                 partial=partial, audio_seconds=round(duration,3), match_seconds=round(match_seconds,6),
                 capture_age=round(time.monotonic()-capture_end,3), capture_end=capture_end, **alignment)
        try:
            text, elapsed = recognize(model, args.model, samples,
                on_partial=lambda t,s: publish(t,s,True),
                cancelled=lambda: snapshot_epoch != state['epoch'] or state['paused'])
            # Pause/manual positioning invalidates in-flight inference.
            if snapshot_epoch == state['epoch'] and not state['paused']:
                publish(text, elapsed)
        except Exception as e:
            if snapshot_epoch == state['epoch'] and not state['paused']:
                emit('error', message='本地识别失败：'+str(e)); state['paused']=True; stop()
        if final:
            chunks, speech_samples, silent_samples = [], 0, 0


if __name__ == '__main__':
    try: main()
    except Exception as e:
        emit('error', message=str(e)); sys.exit(1)
