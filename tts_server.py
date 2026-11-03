import asyncio
import os
import sys
import hashlib
from http.server import HTTPServer, BaseHTTPRequestHandler
import urllib.parse
import edge_tts

AUDIO_CACHE_DIR = os.path.join(os.path.dirname(__file__), "tts_cache")
os.makedirs(AUDIO_CACHE_DIR, exist_ok=True)

class TTSHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path == "/status":
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.end_headers()
            self.wfile.write(b"OK")
            return
            
        if parsed.path == "/tts":
            query = urllib.parse.parse_qs(parsed.query)
            text = query.get("text", [""])[0]
            voice = query.get("voice", ["es-MX-JorgeNeural"])[0]
            rate = query.get("rate", ["+0%"])[0]
            
            if not text:
                self.send_response(400)
                self.end_headers()
                return

            text_hash = hashlib.md5(f"{text}_{voice}_{rate}".encode("utf-8")).hexdigest()
            cache_file = os.path.join(AUDIO_CACHE_DIR, f"{text_hash}.mp3")

            if not os.path.exists(cache_file) or os.path.getsize(cache_file) < 100:
                try:
                    async def run_tts():
                        comm = edge_tts.Communicate(text, voice=voice, rate=rate)
                        await comm.save(cache_file)

                    asyncio.run(run_tts())
                except Exception as e:
                    print(f"TTS Error: {e}", file=sys.stderr)
                    self.send_response(500)
                    self.end_headers()
                    self.wfile.write(str(e).encode("utf-8"))
                    return

            if os.path.exists(cache_file):
                self.send_response(200)
                self.send_header("Content-Type", "audio/mpeg")
                self.send_header("Content-Length", str(os.path.getsize(cache_file)))
                self.send_header("Accept-Ranges", "bytes")
                self.end_headers()
                with open(cache_file, "rb") as f:
                    self.wfile.write(f.read())
            else:
                self.send_response(500)
                self.end_headers()
            return

        self.send_response(404)
        self.end_headers()

def run_server():
    server = HTTPServer(("0.0.0.0", 8090), TTSHandler)
    print("Edge TTS Microservice running on 0.0.0.0:8090")
    server.serve_forever()

if __name__ == "__main__":
    run_server()
