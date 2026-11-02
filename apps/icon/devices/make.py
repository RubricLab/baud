"""The family's devices, the way Meter draws hardware and Apple draws its device pickers: a small flat
tile front-on, the face one step off the surface, a hairline outline and a 1 px soft shadow, the
hardware's real proportions; the screen a plain inset with nothing in it. Two designed sizes: the
hero (64-96) with its details, and the mark (20) that keeps the silhouette and one detail.
Writes <kind>.svg, <kind>-dark.svg, <kind>-mark.svg, <kind>-mark-dark.svg, and the parts as Swift.
   python3 make.py <dir> [swift-out]"""
import os, sys
# Shapes on the 24 grid: ('r', x, y, w, h, r) a rounded rect; ('p', [(x, y), ...]) a polygon.
# Roles: body (face + hairline + shadow), screen (the inset), dark (island, notch), detail (ports, slots, feet).
def r(x, y, w, h, rad): return ('r', x, y, w, h, rad)
ART = {
  'iphone': dict(body=[r(6.55, 5.4, 0.7, 0.8, 0.25), r(6.55, 7.4, 0.7, 1.6, 0.25), r(6.55, 9.8, 0.7, 1.6, 0.25), r(16.75, 8, 0.7, 2.8, 0.25), r(7, 1.5, 10, 21, 2.6)],
                 screen=[r(7.8, 2.3, 8.4, 19.4, 1.9)], dark=[r(10.7, 3.1, 2.6, 0.8, 0.4)], detail=[], mark=['body', 'screen']),
  'ipad': dict(body=[r(4.5, 1.5, 15, 21, 1.9)], screen=[r(5.5, 2.5, 13, 19, 1.1)], dark=[], detail=[], mark=['body', 'screen']),
  'macbook': dict(body=[r(3.5, 4, 17, 12.2, 1.1), r(1.25, 16.2, 21.5, 1.4, 0.7)], screen=[r(4.4, 4.9, 15.2, 10.8, 0.45)],
                  dark=[r(10.9, 4.9, 2.2, 0.7, 0.35)], detail=[r(10.4, 16.2, 3.2, 0.45, 0.22), r(3, 17.6, 1.6, 0.5, 0.25), r(19.4, 17.6, 1.6, 0.5, 0.25)], mark=['body', 'screen']),
  'imac': dict(body=[('p', [(10.2, 17.4), (13.8, 17.4), (14.4, 20.6), (9.6, 20.6)]), r(8.4, 20.3, 7.2, 0.9, 0.45), r(2, 2.5, 20, 15, 1.3)],
               screen=[r(2.9, 3.4, 18.2, 10.6, 0.4)], dark=[], detail=[], mark=['body', 'screen']),
  'mac-mini': dict(body=[r(4, 14.9, 16, 1.6, 0.7), r(2.5, 8.25, 19, 7.25, 2.2)], screen=[], dark=[],
                   detail=[r(6, 11.2, 0.7, 1.6, 0.35), r(7.5, 11.2, 0.7, 1.6, 0.35)], mark=['body', 'detail']),
  'mac-studio': dict(body=[r(4.4, 14.6, 15.2, 1.6, 0.7), r(3, 6.25, 18, 9.25, 2.4)], screen=[], dark=[],
                     detail=[r(5.6, 11.4, 0.7, 1.6, 0.35), r(7.1, 11.4, 0.7, 1.6, 0.35), r(9.4, 12.1, 3.2, 0.6, 0.3)], mark=['body', 'detail']),
  'pc-laptop': dict(body=[r(3.25, 4, 17.5, 12.2, 0.6), r(1.25, 16.2, 21.5, 1.4, 0.4)], screen=[r(4.2, 4.9, 15.6, 10.6, 0.2)], dark=[],
                    detail=[r(10.4, 16.2, 3.2, 0.45, 0.22)], mark=['body', 'screen']),
  'pc-tower': dict(body=[r(6.5, 1.5, 11, 21, 1.1)], screen=[], dark=[], detail=[r(8.6, 4.2, 6.8, 0.6, 0.3), r(8.6, 6, 6.8, 0.6, 0.3)], mark=['body', 'detail']),
  'drive': dict(body=[r(2, 8, 20, 8, 2)], screen=[], dark=[], detail=[r(4.6, 12.6, 5, 0.6, 0.3)], mark=['body', 'detail']),
}
LOOK = {
  'light': dict(face='#ffffff', line='rgba(0,0,0,0.16)', shadow='rgba(0,0,0,0.14)', screen='#ececef', dark='#1c1c1e', detail='rgba(0,0,0,0.38)'),
  'dark': dict(face='#2c2c30', line='rgba(255,255,255,0.16)', shadow='rgba(0,0,0,0.55)', screen='#161618', dark='#000000', detail='rgba(255,255,255,0.4)'),
}
def n(v): return ('%.2f' % v).rstrip('0').rstrip('.')
def shape(s, fill, extra=''):
    if s[0] == 'r': return f'<rect x="{n(s[1])}" y="{n(s[2])}" width="{n(s[3])}" height="{n(s[4])}" rx="{n(s[5])}" fill="{fill}"{extra}/>'
    return f'<path d="M{" L".join(n(x) + " " + n(y) for x, y in s[1])}Z" fill="{fill}"{extra}/>'
def svg(kind, look, mark=False):
    a, c = ART[kind], LOOK[look]
    keep = a['mark'] if mark else ['body', 'screen', 'dark', 'detail']
    line = 1 / (20 / 24) if mark else 1 / (96 / 24)   # one pixel at the size drawn
    out = [f'<defs><filter id="s" x="-20%" y="-20%" width="140%" height="140%"><feDropShadow dx="0" dy="{n(line * 0.6)}" stdDeviation="{n(line * 0.6)}" flood-color="{c["shadow"]}"/></filter></defs>']
    out.append('<g filter="url(#s)">' + ''.join(shape(s, c['face']) for s in a['body']) + '</g>')
    out.append(''.join(shape(s, 'none', f' stroke="{c["line"]}" stroke-width="{n(line)}"') for s in a['body']))
    if 'screen' in keep: out += [shape(s, c['screen']) for s in a['screen']]
    if 'dark' in keep: out += [shape(s, c['dark']) for s in a['dark']]
    if 'detail' in keep: out += [shape(s, c['detail']) for s in a['detail'][: (1 if mark else 99)]]
    size = 20 if mark else 96
    return f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="{size}" height="{size}">' + ''.join(out) + '</svg>\n'
def swift():
    def sw(s): return f'.rect({n(s[1])}, {n(s[2])}, {n(s[3])}, {n(s[4])}, {n(s[5])})' if s[0] == 'r' else '.poly([' + ', '.join(f'({n(x)}, {n(y)})' for x, y in s[1]) + '])'
    out = []
    for k, a in ART.items():
        parts = ', '.join(f'{role}: [{", ".join(sw(s) for s in a[role])}]' for role in ['body', 'screen', 'dark', 'detail'])
        out.append(f'\t\tcase "{k}": return Art({parts}, mark: [{", ".join("." + m for m in a["mark"])}])')
    return '\n'.join(out)
if __name__ == '__main__':
    d = sys.argv[1]
    for k in ART:
        for look in LOOK:
            sfx = '' if look == 'light' else '-dark'
            open(os.path.join(d, f'{k}{sfx}.svg'), 'w').write(svg(k, look))
            open(os.path.join(d, f'{k}-mark{sfx}.svg'), 'w').write(svg(k, look, mark=True))
    if len(sys.argv) > 2: open(sys.argv[2], 'w').write(swift() + '\n')
    print('ok')
