import qrcode from 'qrcode-generator'

/** SVG markup of a QR code (error correction M). Pure; no DOM needed. */
export function qrSvg(text: string, cellSize = 4, margin = 2): string {
  const qr = qrcode(0, 'M')
  qr.addData(text)
  qr.make()
  return qr.createSvgTag({ cellSize, margin, scalable: true })
}
