import math
import struct
import wave
from pathlib import Path
from PIL import Image
import av
import media


class FakeJob:
    id = "media-test"

    def check(self):
        pass

    def progress(self, *args):
        pass


def test_photo_conversion_preserves_original_and_collision(fixture_backup, tmp_path):
    store, backup, photo = fixture_backup
    output = tmp_path / "converted"
    media.convert_photos(store, backup, [photo], output, FakeJob())
    media.convert_photos(store, backup, [photo], output, FakeJob())
    assert len(list(output.glob("*.jpg"))) == 2
    assert Image.open(next(output.glob("*.jpg"))).size == (50, 50)
    assert store.files(backup, query="IMG_0001.PNG")["total"] == 1


def test_windows_ringtone_encoder(tmp_path):
    source = tmp_path / "tone.wav"
    with wave.open(str(source), "wb") as audio:
        audio.setnchannels(1)
        audio.setsampwidth(2)
        audio.setframerate(44100)
        audio.writeframes(
            b"".join(
                struct.pack("<h", int(math.sin(i / 44100 * 440 * math.tau) * 3000))
                for i in range(44100)
            )
        )
    destination = tmp_path / "tone.m4r"
    result = media.create_ringtone(source, destination, FakeJob())
    assert 0.9 <= result["seconds"] <= 1.1
    with av.open(str(destination)) as audio:
        assert audio.streams.audio[0].codec_context.name == "aac"
