"""Draws the Web surface's tiling texture: assets/vfx/web_tile.png.

Overlapping, irregular orb webs (wobbly spokes, polygonal rings with gaps)
over a faint cracked-glass netting and a gauzy haze, with dust specks.
Ivory strands in the colour, how much silk is there in the alpha. Every
mark is drawn at its 9 wrap offsets, so the tile repeats seamlessly. Drawn
at SUPER times the size and scaled down, for clean anti-aliased strands.

    python tools/vfx/make_web_texture.py [--seed N] [--size 1024]
"""
import argparse
import os

import numpy as np
from PIL import Image, ImageDraw
from scipy.spatial import Voronoi

SUPER = 2
WEBS = (4, 3)
NETTING_CELLS = 2600
SPECKS = 70


def periodic_noise(rng, size, scale):
	"""Smooth tiling noise in 0..1: white noise low-passed in frequency space."""
	white = rng.standard_normal((size, size))
	f = np.fft.fftfreq(size)
	radius = np.sqrt(f[:, None] ** 2 + f[None, :] ** 2)
	smooth = np.real(np.fft.ifft2(np.fft.fft2(white) * np.exp(-(radius * scale) ** 2)))
	return (smooth - smooth.min()) / (smooth.max() - smooth.min())


class Layer:
	"""One greyscale coverage layer; lines drawn at every wrap offset."""

	def __init__(self, size):
		self.size = size
		self.image = Image.new("L", (size, size), 0)
		self.draw = ImageDraw.Draw(self.image)

	def line(self, points, value, width):
		for ox in (-self.size, 0, self.size):
			for oy in (-self.size, 0, self.size):
				self.draw.line([(x + ox, y + oy) for x, y in points], fill=int(value), width=int(width), joint="curve")

	def dot(self, x, y, r, value):
		for ox in (-self.size, 0, self.size):
			for oy in (-self.size, 0, self.size):
				self.draw.ellipse((x + ox - r, y + oy - r * 0.8, x + ox + r, y + oy + r * 0.8), fill=int(value))

	def array(self):
		return np.asarray(self.image, dtype=np.float32) / 255.0


def wobbly(rng, a, b, wobble, steps=6):
	"""A line from a to b that sags and wanders a little along its length."""
	a, b = np.asarray(a, float), np.asarray(b, float)
	d = b - a
	normal = np.array([-d[1], d[0]]) / max(np.hypot(*d), 1e-6)
	t = np.linspace(0.0, 1.0, steps)
	sag = np.sin(t * np.pi) * rng.normal(0.0, wobble)
	sag += np.concatenate([[0.0], rng.normal(0.0, wobble * 0.3, steps - 2), [0.0]])
	return [tuple(a + d * ti + normal * s) for ti, s in zip(t, sag)]


def orb_web(rng, layer, size, centre):
	"""One orb web: a hub, wobbly spokes, polygonal rings with gaps."""
	radius = rng.uniform(0.16, 0.3) * size
	spokes = rng.integers(14, 22)
	angles = np.sort(rng.uniform(0, 2 * np.pi) + np.arange(spokes) * 2 * np.pi / spokes + rng.normal(0, 0.06, spokes))
	reach = radius * rng.uniform(0.75, 1.1, spokes)
	strength = rng.uniform(0.55, 1.0)
	width = 4.0 * SUPER
	for angle, r in zip(angles, reach):
		tip = centre + np.array([np.cos(angle), np.sin(angle)]) * r
		layer.line(wobbly(rng, centre, tip, r * 0.015, 8), 255 * strength, width)
	# Rings: tight at the hub, opening out, each spoke-to-spoke run a straight
	# chord at its own jittered radius, so the rings read as cracked polygons.
	ring_r = radius * 0.05
	gap = radius * 0.045
	while ring_r < radius:
		fade = 1.0 - (ring_r / radius) ** 2 * 0.4
		for i in range(spokes):
			j = (i + 1) % spokes
			if rng.random() < 0.05 + 0.2 * ring_r / radius:
				continue
			ri = ring_r * rng.uniform(0.9, 1.1)
			rj = ring_r * rng.uniform(0.9, 1.1)
			if ri > reach[i] or rj > reach[j]:
				continue
			a = centre + np.array([np.cos(angles[i]), np.sin(angles[i])]) * ri
			b = centre + np.array([np.cos(angles[j]), np.sin(angles[j])]) * rj
			layer.line(wobbly(rng, a, b, np.hypot(*(b - a)) * 0.04, 4), 255 * strength * fade, width)
		ring_r += gap * rng.uniform(0.75, 1.25)
		gap *= 1.03


def netting(rng, layer, size):
	"""A faint cracked-glass mesh under the webs: the edges of tiling Voronoi cells."""
	points = rng.uniform(0, size, (NETTING_CELLS, 2))
	tiled = np.concatenate([points + np.array([ox, oy]) * size for ox in (-1, 0, 1) for oy in (-1, 0, 1)])
	vor = Voronoi(tiled)
	for (p, q), ridge in zip(vor.ridge_points, vor.ridge_vertices):
		# Only ridges round the middle tile's points (index 4 of the 9 copies);
		# the wrap offsets draw the rest.
		middle = range(len(points) * 4, len(points) * 5)
		if -1 in ridge or (p not in middle and q not in middle) or rng.random() < 0.3:
			continue
		a, b = vor.vertices[ridge[0]], vor.vertices[ridge[1]]
		layer.line(wobbly(rng, a, b, np.hypot(*(b - a)) * 0.05, 3), 255 * rng.uniform(0.25, 0.55), 2.2 * SUPER)


def main():
	parser = argparse.ArgumentParser()
	parser.add_argument("--seed", type=int, default=7)
	parser.add_argument("--size", type=int, default=1024)
	parser.add_argument("--out", default=os.path.join(os.path.dirname(__file__), "..", "..", "assets", "vfx", "web_tile.png"))
	args = parser.parse_args()
	rng = np.random.default_rng(args.seed)
	big = args.size * SUPER

	webs = Layer(big)
	# One hub per cell of a jittered grid, so the webs spread over the tile
	# instead of clumping.
	cols, rows = WEBS
	for i in range(cols):
		for j in range(rows):
			hub = (np.array([i, j]) + rng.uniform(0.15, 0.85, 2)) * big / np.array([cols, rows])
			orb_web(rng, webs, big, hub)
	net = Layer(big)
	netting(rng, net, big)
	specks = Layer(big)
	for _ in range(SPECKS):
		x, y = rng.uniform(0, big, 2)
		specks.dot(x, y, rng.uniform(2.0, 4.5) * SUPER, 255 * rng.uniform(0.7, 1.0))

	shrink = lambda a: np.asarray(Image.fromarray((a * 255).astype(np.uint8)).resize((args.size, args.size), Image.LANCZOS), np.float32) / 255.0
	silk = shrink(np.maximum(webs.array(), net.array() * 0.8))
	dust = shrink(specks.array())
	# Webs thicken where the haze is heavy and thin out where it parts.
	haze = periodic_noise(rng, args.size, 60.0) * 0.7 + periodic_noise(rng, args.size, 15.0) * 0.3
	silk *= 0.7 + 0.3 * haze
	gauze = np.clip((haze - 0.45) * 0.4, 0.0, 0.15)

	alpha = np.clip(silk + gauze * (1.0 - silk) + dust, 0.0, 1.0)
	ivory = np.array([240, 228, 204], np.float32) / 255.0
	grey = np.array([190, 180, 162], np.float32) / 255.0
	white = np.array([245, 242, 232], np.float32) / 255.0
	strand_share = np.where(alpha > 0, (silk + dust) / np.maximum(alpha, 1e-4), 1.0)[..., None]
	colour = grey + (ivory - grey) * np.clip(strand_share, 0, 1)
	colour = colour + (white - colour) * np.clip(dust * 1.5, 0, 1)[..., None]

	rgba = np.concatenate([colour, alpha[..., None]], axis=-1)
	os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
	Image.fromarray((np.clip(rgba, 0, 1) * 255).astype(np.uint8), "RGBA").save(args.out)
	print(f"wrote {args.out}")


if __name__ == "__main__":
	main()
