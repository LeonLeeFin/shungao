"""Local audio decoding shared by validation and the private ASR worker."""
import numpy as np
import soundfile as sf
import miniaudio


def prepare_audio(samples, rate, target=16000):
    samples = np.asarray(samples, dtype=np.float32)
    if samples.ndim == 2:
        samples = samples.mean(axis=1)
    if samples.ndim != 1 or not samples.size:
        raise ValueError('音频为空或声道格式无效')
    if rate <= 0 or not np.isfinite(samples).all():
        raise ValueError('音频采样率或样本无效')
    if rate != target:
        wanted = round(len(samples) * target / rate)
        converted = miniaudio.convert_frames(
            miniaudio.SampleFormat.FLOAT32, 1, int(rate), samples.tobytes(),
            miniaudio.SampleFormat.FLOAT32, 1, target)
        samples = np.frombuffer(converted, dtype=np.float32)[:wanted]
    return np.ascontiguousarray(np.clip(samples, -1, 1), dtype=np.float32)


def read_audio(path):
    # libsndfile supports the AIFF-C file produced by macOS say, unlike miniaudio.
    try:
        samples, rate = sf.read(path, dtype='float32', always_2d=True)
        return prepare_audio(samples, rate)
    except (RuntimeError, ValueError) as error:
        raise ValueError('无法读取音频；请使用 WAV、AIFF 或 FLAC：' + str(error)) from error
