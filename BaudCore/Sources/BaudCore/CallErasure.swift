/// Media 2's parity: a Reed-Solomon erasure code over GF(256), so a frame comes back whole from any
/// `k` of its `k + m` pieces, not just when one in a group goes missing (the XOR parity media 1
/// has). A frame's pieces go in blocks of at most `Erasure.block`; each block gets `m` parity pieces
/// (Cauchy rows: any k of the k + m rows are independent), each the size of the block's longest
/// piece with its length in front. How many is the sender's call: enough that, at the loss it
/// measures, a block comes back short less than one time in five hundred (`parity(for:loss:)`).
import Foundation

public enum Erasure {
	/// The most data pieces in one block: the solve is cubic in what's missing, at most m.
	public static let block = 32

	private static let tables: (exp: [UInt8], log: [Int]) = {
		var exp = [UInt8](repeating: 0, count: 512), log = [Int](repeating: 0, count: 256)
		var x = 1
		for i in 0..<255 {
			exp[i] = UInt8(x); log[x] = i
			x <<= 1
			if x & 0x100 != 0 { x ^= 0x11d }
		}
		for i in 255..<512 { exp[i] = exp[i - 255] }
		return (exp, log)
	}()

	@inline(__always) static func mul(_ a: UInt8, _ b: UInt8) -> UInt8 {
		a == 0 || b == 0 ? 0 : tables.exp[tables.log[Int(a)] + tables.log[Int(b)]]
	}
	@inline(__always) static func inv(_ a: UInt8) -> UInt8 { tables.exp[255 - tables.log[Int(a)]] }

	/// Row j's weight for data piece i: 1 / (x_j + y_i), x_j = 128 + j, y_i = i.
	@inline(__always) static func weight(_ j: Int, _ i: Int) -> UInt8 { inv(UInt8(128 + j) ^ UInt8(i)) }

	/// `out += c · x`, byte by byte.
	static func addScaled(_ out: inout [UInt8], _ x: [UInt8], _ c: UInt8) {
		guard c != 0 else { return }
		let lc = tables.log[Int(c)]
		tables.exp.withUnsafeBufferPointer { exp in
			tables.log.withUnsafeBufferPointer { log in
				out.withUnsafeMutableBufferPointer { o in
					x.withUnsafeBufferPointer { xs in
						for n in 0..<min(o.count, xs.count) where xs[n] != 0 { o[n] ^= exp[log[Int(xs[n])] + lc] }
					}
				}
			}
		}
	}

	/// `m` parity pieces for these data pieces (each prefixed with its length, padded to the longest).
	public static func parity(_ pieces: [Data], m: Int) -> [Data] {
		guard m > 0, !pieces.isEmpty else { return [] }
		let rows = pieces.map { [UInt8](prefixed($0)) }
		let n = rows.map(\.count).max()!
		return (0..<m).map { j in
			var p = [UInt8](repeating: 0, count: n)
			for (i, r) in rows.enumerated() { addScaled(&p, r, weight(j, i)) }
			return Data(p)
		}
	}

	/// The missing data pieces of a block from the ones here and enough parity: `have` by index
	/// in the block (0..<k), `parity` by row. Nil when there isn't enough.
	public static func recover(k: Int, have: [Int: Data], parity: [Int: Data]) -> [Int: Data]? {
		let missing = (0..<k).filter { have[$0] == nil }
		guard !missing.isEmpty else { return [:] }
		let rows = parity.keys.sorted().prefix(missing.count)
		guard rows.count == missing.count else { return nil }
		let n = parity.values.map(\.count).max()!
		// Each chosen row less what the pieces here contribute: what's left is the missing ones'.
		var rhs: [[UInt8]] = rows.map { j in
			var r = [UInt8](parity[j]!); if r.count < n { r += [UInt8](repeating: 0, count: n - r.count) }
			for (i, d) in have { addScaled(&r, [UInt8](prefixed(d)), weight(j, i)) }
			return r
		}
		var a: [[UInt8]] = rows.map { j in missing.map { weight(j, $0) } }
		// Gauss-Jordan on the small square system, the right-hand sides carried along.
		let size = missing.count
		for col in 0..<size {
			guard let pivot = (col..<size).first(where: { a[$0][col] != 0 }) else { return nil }
			a.swapAt(col, pivot); rhs.swapAt(col, pivot)
			let f = inv(a[col][col])
			a[col] = a[col].map { mul($0, f) }
			rhs[col] = rhs[col].map { mul($0, f) }
			for r in 0..<size where r != col && a[r][col] != 0 {
				let c = a[r][col]
				for x in 0..<size { a[r][x] ^= mul(a[col][x], c) }
				addScaled(&rhs[r], rhs[col], c)
			}
		}
		var out: [Int: Data] = [:]
		for (row, i) in missing.enumerated() {
			let b = rhs[row]
			guard b.count >= 2 else { return nil }
			let len = Int(b[0]) << 8 | Int(b[1])
			guard 2 + len <= b.count else { return nil }
			out[i] = Data(b[2..<2 + len])
		}
		return out
	}

	/// Parity pieces for a block of `k` at a loss rate: the fewest that leave it short less than
	/// one time in five hundred (loss taken as at least 0.3%, so a clean path still has one).
	public static func parity(for k: Int, loss: Double) -> Int {
		let p = min(0.5, max(0.003, loss))
		for m in 0...k {
			// The chance no more than m of the k + m go missing, term by binomial term.
			let n = k + m
			var term = pow(1 - p, Double(n)), within = term
			if m > 0 { for x in 1...m { term *= Double(n - x + 1) / Double(x) * p / (1 - p); within += term } }
			if 1 - within < 0.002 { return m }
		}
		return k
	}
}
