#!/usr/bin/env python3
"""
WhisperX transcription with speaker diarization.

Outputs JSON to stdout:
  {"text": "...", "segments": [{"speaker": "Speaker 1", "text": "...", "start": 0.0, "end": 1.5}, ...]}

On error:
  {"error": "..."}
"""

import argparse
import json
import sys
import warnings

warnings.filterwarnings("ignore")


def main():
    parser = argparse.ArgumentParser(description="WhisperX transcription with speaker diarization")
    parser.add_argument("audio", help="Path to audio file")
    parser.add_argument("--model", default="small.en", help="Whisper model name (default: small.en)")
    parser.add_argument("--device", default="auto", help="Device: auto, cpu, or cuda (default: auto)")
    parser.add_argument("--hf-token", required=True, help="HuggingFace token for pyannote diarization models")
    parser.add_argument("--language", default="en", help="Language code (default: en)")
    parser.add_argument("--prompt", default="", help="Initial prompt for transcription context")
    parser.add_argument("--compute-type", default="auto",
                        help="CTranslate2 compute type: auto, int8, float16, float32 (default: auto)")
    args = parser.parse_args()

    try:
        import torch
        import whisperx

        if args.device == "auto":
            device = "cuda" if torch.cuda.is_available() else "cpu"
        else:
            device = args.device

        compute_type = args.compute_type
        if compute_type == "auto":
            compute_type = "int8" if device == "cuda" else "float32"

        # 1. Transcribe
        model = whisperx.load_model(
            args.model,
            device,
            compute_type=compute_type,
            language=args.language,
        )

        audio = whisperx.load_audio(args.audio)

        transcribe_opts = {}
        if args.prompt:
            transcribe_opts["initial_prompt"] = args.prompt

        result = model.transcribe(audio, **transcribe_opts)

        if not result.get("segments"):
            output = {"text": "", "segments": []}
            json.dump(output, sys.stdout)
            return

        # 2. Align word-level timestamps
        try:
            model_a, metadata = whisperx.load_align_model(
                language_code=result["language"],
                device=device,
            )
            result = whisperx.align(
                result["segments"],
                model_a,
                metadata,
                audio,
                device,
                return_char_alignments=False,
            )
        except Exception:
            # Alignment can fail for some languages; continue without it
            pass

        # 3. Speaker diarization
        diarize_model = whisperx.DiarizationPipeline(
            use_auth_token=args.hf_token,
            device=device,
        )
        diarize_segments = diarize_model(args.audio)

        # 4. Assign speakers to segments
        result = whisperx.assign_word_speakers(diarize_segments, result)

        # 5. Build output -- merge consecutive segments from same speaker
        merged = []
        for seg in result.get("segments", []):
            speaker = seg.get("speaker", "Unknown")
            text = seg.get("text", "").strip()
            start = seg.get("start", 0.0)
            end = seg.get("end", 0.0)

            if not text:
                continue

            if merged and merged[-1]["speaker"] == speaker:
                merged[-1]["text"] += " " + text
                merged[-1]["end"] = end
            else:
                merged.append({
                    "speaker": speaker,
                    "text": text,
                    "start": round(start, 2),
                    "end": round(end, 2),
                })

        # Renumber speakers sequentially (SPEAKER_00 -> Speaker 1, etc.)
        speaker_map = {}
        counter = 1
        for seg in merged:
            raw = seg["speaker"]
            if raw not in speaker_map:
                speaker_map[raw] = f"Speaker {counter}"
                counter += 1
            seg["speaker"] = speaker_map[raw]

        # Build formatted text
        formatted_parts = []
        for seg in merged:
            formatted_parts.append(f"[{seg['speaker']}]: {seg['text']}")

        output = {
            "text": " ".join(formatted_parts),
            "segments": merged,
        }

        json.dump(output, sys.stdout)

    except ImportError as e:
        json.dump({"error": f"Missing dependency: {e}. Install whisperx: pip install whisperx"}, sys.stdout)
        sys.exit(1)
    except Exception as e:
        json.dump({"error": str(e)}, sys.stdout)
        sys.exit(1)


if __name__ == "__main__":
    main()
