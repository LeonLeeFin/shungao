import sys
import unittest
import tempfile
from pathlib import Path
import numpy as np
import soundfile as sf
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'engine'))
from audio_input import read_audio, prepare_audio


class AudioInputTests(unittest.TestCase):
    def test_generated_aiff_decodes_and_resamples(self):
        sample_rate = 22050
        signal = np.sin(2 * np.pi * 440 * np.arange(sample_rate) / sample_rate) * .4
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'signal.aiff'
            sf.write(path, signal, sample_rate, format='AIFF', subtype='PCM_16')
            info = sf.info(path)
            samples = read_audio(path)
        self.assertEqual(samples.dtype, np.float32)
        self.assertEqual(samples.ndim, 1)
        self.assertLess(abs(len(samples) / 16000 - info.duration), 1 / 16000)
        self.assertGreater(np.max(np.abs(samples)), .05)

    def test_stereo_and_48khz(self):
        signal = np.sin(2 * np.pi * 440 * np.arange(48000) / 48000) * .4
        stereo = np.stack((signal, signal * .5), axis=1)
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'stereo.wav'
            sf.write(path, stereo, 48000)
            samples = read_audio(path)
        self.assertEqual(samples.shape, (16000,))
        self.assertAlmostEqual(float(np.max(samples)), .3, delta=.02)

    def test_invalid_audio_is_rejected(self):
        for samples in [[], [float('nan')], [float('inf')]]:
            with self.assertRaises(ValueError):
                prepare_audio(samples, 16000)


if __name__ == '__main__':
    unittest.main(verbosity=2)
