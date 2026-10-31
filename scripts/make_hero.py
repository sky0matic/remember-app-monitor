#!/usr/bin/env python3
"""Builds docs/screenshots/settings-hero.png: the light and dark screenshots of the
settings window, overlapping on a light-to-dark gradient. Run after updating the
two screenshots: python3 scripts/make_hero.py"""

import pathlib

from PySide6.QtCore import QPointF, QRectF, Qt
from PySide6.QtGui import QColor, QGuiApplication, QImage, QLinearGradient, QPainter, QPainterPath

SHOTS = pathlib.Path(__file__).resolve().parent.parent / "docs" / "screenshots"
CANVAS_W, CANVAS_H = 1280, 800
SCALE = 0.82
MARGIN = 56
RADIUS = 10


def rounded(rect):
    path = QPainterPath()
    path.addRoundedRect(rect, RADIUS, RADIUS)
    return path


def shadow(size, blur=28, alpha=110):
    """A soft shadow for a window of the given size, as an image `blur` px larger on each side."""
    w, h = size.width() + 2 * blur, size.height() + 2 * blur
    img = QImage(w, h, QImage.Format_ARGB32_Premultiplied)
    img.fill(Qt.transparent)
    p = QPainter(img)
    p.setRenderHint(QPainter.Antialiasing)
    p.fillPath(rounded(QRectF(blur, blur, size.width(), size.height())), QColor(0, 0, 0, alpha))
    p.end()
    # cheap blur: scale down and back up a few times
    for factor in (8, 4):
        img = img.scaled(w // factor, h // factor, Qt.IgnoreAspectRatio, Qt.SmoothTransformation)
        img = img.scaled(w, h, Qt.IgnoreAspectRatio, Qt.SmoothTransformation)
    return img


def draw_window(p, shot, pos, blur=28):
    size = shot.size()
    p.drawImage(QPointF(pos.x() - blur, pos.y() - blur + 10), shadow(size, blur))
    p.save()
    p.setClipPath(rounded(QRectF(pos, size)))
    p.drawImage(pos, shot)
    p.restore()


def main():
    app = QGuiApplication.instance() or QGuiApplication([])  # noqa: F841 (QPainter needs one)
    light = QImage(str(SHOTS / "settings-light.png"))
    dark = QImage(str(SHOTS / "settings-dark.png"))
    w, h = int(light.width() * SCALE), int(light.height() * SCALE)
    light = light.scaled(w, h, Qt.IgnoreAspectRatio, Qt.SmoothTransformation)
    dark = dark.scaled(w, h, Qt.IgnoreAspectRatio, Qt.SmoothTransformation)

    out = QImage(CANVAS_W, CANVAS_H, QImage.Format_ARGB32_Premultiplied)
    p = QPainter(out)
    p.setRenderHint(QPainter.Antialiasing)
    p.setRenderHint(QPainter.SmoothPixmapTransform)
    gradient = QLinearGradient(0, 0, CANVAS_W, CANVAS_H)
    gradient.setColorAt(0.0, QColor("#e9edf3"))
    gradient.setColorAt(0.45, QColor("#9aa6b8"))
    gradient.setColorAt(1.0, QColor("#1b1f27"))
    p.fillRect(out.rect(), gradient)

    draw_window(p, light, QPointF(MARGIN, MARGIN))
    draw_window(p, dark, QPointF(CANVAS_W - MARGIN - w, CANVAS_H - MARGIN - h))
    p.end()
    out.save(str(SHOTS / "settings-hero.png"))
    print(SHOTS / "settings-hero.png")


if __name__ == "__main__":
    main()
