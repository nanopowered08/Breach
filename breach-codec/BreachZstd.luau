--!nonstrict
--[[
	BreachZstd — Zstandard (RFC 8878) decompressor in pure Luau.
	Companion to BreachCodec.luau; use it as the `zstdDecompress` host function:

	    local Zstd = require("./BreachZstd")
	    local m, err = Codec.decode(text, { zstdDecompress = Zstd.decompress })

	  Zstd.decompress(data: string, maxOutput: number?) -> string | nil, err

	Supports: every block type (raw, RLE, compressed), Huffman literals (1 or 4 streams, FSE-coded or direct
	weights, treeless reuse), all sequence modes (predefined, RLE, FSE, repeat), repeat offsets, multiple
	frames, skippable frames, single-segment and windowed frames.
	Does NOT support: dictionaries (dictionary id != 0 is rejected). The optional XXH64 content checksum is
	skipped, not verified.

	Requires the Luau `buffer` library (core Luau since late 2023) and `bit32`. No other dependencies.
	Written from the RFC; contains no code from any Zstandard implementation.
]]

local Zstd = {}

local byte, sub = string.byte, string.sub

local DEFAULT_MAX_OUTPUT = 512 * 1024 * 1024

local function fail(msg)
	error("BreachZstd: " .. msg, 0)
end

local POW2 = {}
for i = 0, 53 do
	POW2[i] = 2 ^ i
end

local function highbit(x) -- floor(log2(x)), x >= 1
	local n = 0
	while x >= 2 do
		x = x // 2
		n = n + 1
	end
	return n
end

-------------------------------------------------------------------------------
-- Bit readers
-------------------------------------------------------------------------------

-- Raw bits [p, p+n) (LSB-first numbering within the byte range starting at byte `first`), n <= 32.
-- Bytes outside the string read as 0.
local function bitsAt(s, first, p, n)
	local b = p // 8
	local sh = p - b * 8
	local nb = (sh + n + 7) // 8
	local b1, b2, b3, b4, b5 = byte(s, first + b, first + b + nb - 1)
	local acc = (b1 or 0) + (b2 or 0) * 256 + (b3 or 0) * 65536 + (b4 or 0) * 16777216 + (b5 or 0) * 4294967296
	return (acc // POW2[sh]) % POW2[n]
end

-- Backward bit stream over bytes [first, last] of s; the last byte holds a sentinel 1-bit marking the start.
-- br.pos = number of unread data bits. Reading below 0 zero-fills and leaves pos negative (= overflow).
local function brInit(s, first, last)
	if last < first then
		fail("empty bitstream")
	end
	local lb = byte(s, last)
	if lb == nil or lb == 0 then
		fail("bitstream has no sentinel bit")
	end
	return { s = s, first = first, pos = (last - first) * 8 + highbit(lb) }
end

local function brRead(br, n)
	if n == 0 then
		return 0
	end
	local pos = br.pos - n
	br.pos = pos
	if pos >= 0 then
		return bitsAt(br.s, br.first, pos, n)
	end
	local have = pos + n -- bits that really exist
	if have <= 0 then
		return 0
	end
	return bitsAt(br.s, br.first, 0, have) * POW2[-pos]
end

local function brPeek(br, n) -- like brRead but does not consume
	local pos = br.pos - n
	if pos >= 0 then
		return bitsAt(br.s, br.first, pos, n)
	end
	local have = pos + n
	if have <= 0 then
		return 0
	end
	return bitsAt(br.s, br.first, 0, have) * POW2[-pos]
end

-------------------------------------------------------------------------------
-- FSE
-------------------------------------------------------------------------------

-- probs: array indexed 0..maxSym of normalised counts (-1 = "less than one"), al = accuracy log
local function buildFSE(probs, maxSym, al)
	local size = POW2[al]
	local T, nextState = {}, {}
	local high = size - 1
	for s = 0, maxSym do
		local p = probs[s] or 0
		if p == -1 then
			T[high] = s
			high = high - 1
			nextState[s] = 1
		else
			nextState[s] = p
		end
	end
	local step = size // 2 + size // 8 + 3
		local pos = 0
	for s = 0, maxSym do
		local p = probs[s] or 0
		for _ = 1, p do
			T[pos] = s
			pos = (pos + step) % size
			while pos > high do
				pos = (pos + step) % size
			end
		end
	end
	if pos ~= 0 then
		fail("corrupt FSE distribution")
	end
	local sym, nb, base = {}, {}, {}
	for u = 0, size - 1 do
		local s = T[u]
		local ns = nextState[s]
		nextState[s] = ns + 1
		local bits = al - highbit(ns)
		sym[u] = s
		nb[u] = bits
		base[u] = ns * POW2[bits] - size
	end
	return { al = al, sym = sym, nb = nb, base = base }
end

-- Reads an FSE distribution header starting at byte `start` (1-based). Returns table, nextByteIndex.
local function readFSETable(s, start, limit, maxAL, maxSymLimit)
	local bp = 0 -- bit position from `start`
	local function rd(n)
		local v = bitsAt(s, start, bp, n)
		bp = bp + n
		return v
	end
	if start > limit then
		fail("FSE header past end of data")
	end
	local al = rd(4) + 5
	if al > maxAL then
		fail("FSE accuracy log " .. al .. " exceeds limit " .. maxAL)
	end
	local remaining = POW2[al] + 1
	local threshold = POW2[al]
	local nbBits = al + 1
	local probs = {}
	local sym = 0
	local prevZero = false
	while remaining > 1 and sym <= maxSymLimit do
		if prevZero then
			-- run of zero-probability symbols: 2-bit repeat flags
			while true do
				local r = rd(2)
				for _ = 1, r do
					probs[sym] = 0
					sym = sym + 1
				end
				if r ~= 3 then
					break
				end
			end
			prevZero = false
			if sym > maxSymLimit then
				break
			end
		end
		local mx = (2 * threshold - 1) - remaining
		local lowBits = bitsAt(s, start, bp, nbBits - 1)
		local count
		if lowBits < mx then
			count = lowBits
			bp = bp + nbBits - 1
		else
			local full = bitsAt(s, start, bp, nbBits)
			count = full % (2 * threshold)
			if count >= threshold then
				count = count - mx
			end
			bp = bp + nbBits
		end
		count = count - 1
		remaining = remaining - (count < 0 and -count or count)
		probs[sym] = count
		sym = sym + 1
		if count == 0 then
			prevZero = true
		end
		while remaining < threshold do
			nbBits = nbBits - 1
			threshold = threshold // 2
		end
	end
	if remaining ~= 1 then
		fail("corrupt FSE distribution header")
	end
	local used = (bp + 7) // 8
	if start + used - 1 > limit then
		fail("FSE header runs past end of data")
	end
	return buildFSE(probs, sym - 1, al), start + used
end

-------------------------------------------------------------------------------
-- Huffman
-------------------------------------------------------------------------------

local function buildHuffman(weights) -- weights: array 1..n for symbols 0..n-1 (last weight inferred by caller)
	local n = #weights
	local sum = 0
	for i = 1, n do
		local w = weights[i]
		if w > 0 then
			sum = sum + POW2[w - 1]
		end
	end
	if sum == 0 then
		fail("Huffman table has no symbols")
	end
	local maxBits = highbit(sum) + 1
	if maxBits > 11 then
		fail("Huffman code longer than 11 bits")
	end
	local rest = POW2[maxBits] - sum
	if rest <= 0 or rest ~= POW2[highbit(rest)] then
		fail("Huffman weights do not complete a power of two")
	end
	weights[n + 1] = highbit(rest) + 1
	n = n + 1
	local size = POW2[maxBits]
	local symT, nbT = {}, {}
	local pos = 0
	for w = 1, maxBits do
		local span = POW2[w - 1]
		local bits = maxBits + 1 - w
		for s = 1, n do
			if weights[s] == w then
				for k = pos, pos + span - 1 do
					symT[k] = s - 1
					nbT[k] = bits
				end
				pos = pos + span
			end
		end
	end
	if pos ~= size then
		fail("Huffman table fill mismatch")
	end
	return { maxBits = maxBits, sym = symT, nb = nbT }
end

-- Reads the Huffman tree description at byte `start`; returns table, nextByteIndex
local function readHuffmanTree(s, start, limit)
	local hb = byte(s, start)
	if hb == nil then
		fail("Huffman header past end of data")
	end
	local weights = {}
	local nextIdx
	if hb >= 128 then
		local n = hb - 127
		local nbytes = (n + 1) // 2
		if start + nbytes > limit then
			fail("direct Huffman weights run past end of data")
		end
		for i = 0, n - 1 do
			local b = byte(s, start + 1 + i // 2)
			weights[i + 1] = (i % 2 == 0) and (b // 16) or (b % 16)
		end
		nextIdx = start + 1 + nbytes
	else
		local csize = hb
		if csize == 0 or start + csize > limit then
			fail("bad FSE-compressed Huffman weights size")
		end
		local tbl, after = readFSETable(s, start + 1, start + csize, 6, 255)
		if after > start + csize + 1 then
			fail("Huffman weights FSE header overruns its section")
		end
		local br = brInit(s, after, start + csize)
		local state1 = brRead(br, tbl.al)
		local state2 = brRead(br, tbl.al)
		local symT, nbT, baseT = tbl.sym, tbl.nb, tbl.base
		local count = 0
		while true do
			if count >= 255 then
				fail("too many Huffman weights")
			end
			weights[count + 1] = symT[state1]
			count = count + 1
			state1 = baseT[state1] + brRead(br, nbT[state1])
			if br.pos < 0 then
				weights[count + 1] = symT[state2]
				count = count + 1
				break
			end
			weights[count + 1] = symT[state2]
			count = count + 1
			state2 = baseT[state2] + brRead(br, nbT[state2])
			if br.pos < 0 then
				weights[count + 1] = symT[state1]
				count = count + 1
				break
			end
		end
		nextIdx = start + 1 + csize
	end
	for i = 1, #weights do
		if weights[i] > 11 then
			fail("Huffman weight out of range")
		end
	end
	return buildHuffman(weights), nextIdx
end

-- decode `count` symbols from one backward stream into dst at offset
local function huffDecodeStream(s, first, last, huf, dst, dstOff, count)
	local br = brInit(s, first, last)
	local maxBits, symT, nbT = huf.maxBits, huf.sym, huf.nb
	for i = 0, count - 1 do
		local v = brPeek(br, maxBits)
		br.pos = br.pos - nbT[v]
		buffer.writeu8(dst, dstOff + i, symT[v])
	end
	if br.pos ~= 0 then
		fail("Huffman stream not fully consumed (corrupt literals)")
	end
end

-------------------------------------------------------------------------------
-- Sequence code tables
-------------------------------------------------------------------------------
local LL_BASE = { [0] = 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 18, 20, 22, 24, 28, 32, 40, 48, 64, 128, 256, 512, 1024, 2048, 4096, 8192, 16384, 32768, 65536 }
local LL_BITS = { [0] = 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 3, 3, 4, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 }
local ML_BASE = { [0] = 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 37, 39, 41, 43, 47, 51, 59, 67, 83, 99, 131, 259, 515, 1027, 2051, 4099, 8195, 16387, 32771, 65539 }
local ML_BITS = { [0] = 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 3, 3, 4, 4, 5, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 }

local LL_DEFAULT = { [0] = 4, 3, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 1, 1, 1, 2, 2, 2, 2, 2, 2, 2, 2, 2, 3, 2, 1, 1, 1, 1, 1, -1, -1, -1, -1 }
local ML_DEFAULT = { [0] = 1, 4, 3, 2, 2, 2, 2, 2, 2 } -- then 37 ones (codes 9..45) and 7 x -1 (codes 46..52)
for i = 9, 45 do
	ML_DEFAULT[i] = 1
end
for i = 46, 52 do
	ML_DEFAULT[i] = -1
end
local OF_DEFAULT = { [0] = 1, 1, 1, 1, 1, 1, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, -1, -1, -1, -1, -1 }

local PREDEF -- built lazily
local function predefined()
	if not PREDEF then
		PREDEF = {
			ll = buildFSE(LL_DEFAULT, 35, 6),
			ml = buildFSE(ML_DEFAULT, 52, 6),
			of = buildFSE(OF_DEFAULT, 28, 5),
		}
	end
	return PREDEF
end

-------------------------------------------------------------------------------
-- Output buffer
-------------------------------------------------------------------------------
local function newOut(hint)
	return { buf = buffer.create(math.max(hint or 0, 4096)), len = 0 }
end

local function ensure(out, extra, maxOut)
	local need = out.len + extra
	if need > maxOut then
		fail("output would exceed the allowed maximum (" .. maxOut .. " bytes)")
	end
	local cap = buffer.len(out.buf)
	if need > cap then
		local ncap = cap * 2
		if ncap < need then
			ncap = need
		end
		if ncap > maxOut then
			ncap = maxOut
		end
		local nb = buffer.create(ncap)
		buffer.copy(nb, 0, out.buf, 0, out.len)
		out.buf = nb
	end
end

-------------------------------------------------------------------------------
-- Block decoding
-------------------------------------------------------------------------------

local function decodeLiterals(s, p, blockEnd, st)
	local b0 = byte(s, p)
	if b0 == nil then
		fail("literals header past end of data")
	end
	local ltype = b0 % 4
	local sf = (b0 // 4) % 4
	if ltype <= 1 then -- raw / RLE
		local regen, hdr
		if sf == 0 or sf == 2 then
			regen, hdr = b0 // 8, 1
		elseif sf == 1 then
			regen, hdr = b0 // 16 + (byte(s, p + 1) or 0) * 16, 2
		else
			regen, hdr = b0 // 16 + (byte(s, p + 1) or 0) * 16 + (byte(s, p + 2) or 0) * 4096, 3
		end
		local lit = buffer.create(math.max(regen, 1))
		if ltype == 0 then
			if p + hdr + regen - 1 > blockEnd then
				fail("raw literals run past end of block")
			end
			buffer.writestring(lit, 0, sub(s, p + hdr, p + hdr + regen - 1))
			return lit, regen, p + hdr + regen
		end
		local v = byte(s, p + hdr)
		if v == nil then
			fail("RLE literal past end of data")
		end
		for i = 0, regen - 1 do
			buffer.writeu8(lit, i, v)
		end
		return lit, regen, p + hdr + 1
	end
	-- compressed / treeless
	local hdr, streams, regenBits
	if sf == 0 then
		hdr, streams, regenBits = 3, 1, 10
	elseif sf == 1 then
		hdr, streams, regenBits = 3, 4, 10
	elseif sf == 2 then
		hdr, streams, regenBits = 4, 4, 14
	else
		hdr, streams, regenBits = 5, 4, 18
	end
	local v = 0
	for i = 0, hdr - 1 do
		v = v + (byte(s, p + i) or 0) * POW2[8 * i]
	end
	v = v // 16
	local regen = v % POW2[regenBits]
	local csize = (v // POW2[regenBits]) % POW2[regenBits]
	local dataStart = p + hdr
	local dataEnd = dataStart + csize - 1
	if dataEnd > blockEnd then
		fail("compressed literals run past end of block")
	end
	local huf
	local cur = dataStart
	if ltype == 2 then
		huf, cur = readHuffmanTree(s, cur, dataEnd)
		st.huf = huf
	else
		huf = st.huf
		if huf == nil then
			fail("treeless literals without a previous Huffman table")
		end
	end
	local lit = buffer.create(math.max(regen, 1))
	if streams == 1 then
		huffDecodeStream(s, cur, dataEnd, huf, lit, 0, regen)
	else
		if cur + 5 > dataEnd then
			fail("jump table past end of literals")
		end
		local s1 = byte(s, cur) + byte(s, cur + 1) * 256
		local s2 = byte(s, cur + 2) + byte(s, cur + 3) * 256
		local s3 = byte(s, cur + 4) + byte(s, cur + 5) * 256
		local a = cur + 6
		local e1, e2, e3 = a + s1 - 1, a + s1 + s2 - 1, a + s1 + s2 + s3 - 1
		if e3 >= dataEnd then
			fail("literal stream sizes exceed section")
		end
		local per = (regen + 3) // 4
		local last = regen - 3 * per
		if last < 0 then
			fail("bad literal stream split")
		end
		huffDecodeStream(s, a, e1, huf, lit, 0, per)
		huffDecodeStream(s, e1 + 1, e2, huf, lit, per, per)
		huffDecodeStream(s, e2 + 1, e3, huf, lit, 2 * per, per)
		huffDecodeStream(s, e3 + 1, dataEnd, huf, lit, 3 * per, last)
	end
	return lit, regen, dataEnd + 1
end

local function setupSeqTable(mode, s, p, blockEnd, st, key, defaultTbl, maxAL, maxSym)
	if mode == 0 then
		return defaultTbl(), p
	elseif mode == 1 then
		local sym = byte(s, p)
		if sym == nil or p > blockEnd then
			fail("RLE sequence symbol past end of block")
		end
		if sym > maxSym then
			fail("RLE sequence symbol out of range")
		end
		return { al = 0, sym = { [0] = sym }, nb = { [0] = 0 }, base = { [0] = 0 } }, p + 1
	elseif mode == 2 then
		return readFSETable(s, p, blockEnd, maxAL, maxSym)
	end
	local t = st[key]
	if t == nil then
		fail("repeat sequence table with no previous table")
	end
	return t, p
end

local function decodeBlock(s, p, blockEnd, st, out, maxOut)
	local lit, litLen, q = decodeLiterals(s, p, blockEnd, st)
	-- sequences header
	local n0 = byte(s, q)
	if n0 == nil or q > blockEnd then
		fail("sequences header past end of block")
	end
	local nseq
	if n0 == 0 then
		nseq = 0
		q = q + 1
	elseif n0 < 128 then
		nseq = n0
		q = q + 1
	elseif n0 < 255 then
		nseq = (n0 - 128) * 256 + byte(s, q + 1)
		q = q + 2
	else
		nseq = byte(s, q + 1) + byte(s, q + 2) * 256 + 0x7F00
		q = q + 3
	end
	if nseq == 0 then
		ensure(out, litLen, maxOut)
		buffer.copy(out.buf, out.len, lit, 0, litLen)
		out.len = out.len + litLen
		return
	end
	local modes = byte(s, q)
	if modes == nil then
		fail("missing symbol compression modes")
	end
	q = q + 1
	if modes % 4 ~= 0 then
		fail("reserved bits set in symbol compression modes")
	end
	local llMode, ofMode, mlMode = modes // 64, (modes // 16) % 4, (modes // 4) % 4
	local pre = predefined
	local llT, ofT, mlT
	llT, q = setupSeqTable(llMode, s, q, blockEnd, st, "ll", function() return pre().ll end, 9, 35)
	ofT, q = setupSeqTable(ofMode, s, q, blockEnd, st, "of", function() return pre().of end, 8, 31)
	mlT, q = setupSeqTable(mlMode, s, q, blockEnd, st, "ml", function() return pre().ml end, 9, 52)
	st.ll, st.of, st.ml = llT, ofT, mlT

	local br = brInit(s, q, blockEnd)
	local llState = brRead(br, llT.al)
	local ofState = brRead(br, ofT.al)
	local mlState = brRead(br, mlT.al)
	local llSym, llNb, llBase = llT.sym, llT.nb, llT.base
	local ofSym, ofNb, ofBase = ofT.sym, ofT.nb, ofT.base
	local mlSym, mlNb, mlBase = mlT.sym, mlT.nb, mlT.base

	local rep1, rep2, rep3 = st.rep1, st.rep2, st.rep3
	local ob = out.buf
	local litPos = 0

	for i = 1, nseq do
		local ofCode = ofSym[ofState]
		local mlCode = mlSym[mlState]
		local llCode = llSym[llState]
		local offsetValue = POW2[ofCode] + brRead(br, ofCode)
		local matchLen = ML_BASE[mlCode] + brRead(br, ML_BITS[mlCode])
		local litLenV = LL_BASE[llCode] + brRead(br, LL_BITS[llCode])
		if br.pos < 0 then
			fail("sequence bitstream overflow (corrupt block)")
		end
		if i < nseq then
			llState = llBase[llState] + brRead(br, llNb[llState])
			mlState = mlBase[mlState] + brRead(br, mlNb[mlState])
			ofState = ofBase[ofState] + brRead(br, ofNb[ofState])
		end

		local offset
		if offsetValue > 3 then
			offset = offsetValue - 3
			rep3, rep2, rep1 = rep2, rep1, offset
		else
			local idx = offsetValue
			if litLenV == 0 then
				idx = idx + 1
			end
			if idx == 1 then
				offset = rep1
			elseif idx == 2 then
				offset = rep2
				rep2, rep1 = rep1, offset
			elseif idx == 3 then
				offset = rep3
				rep3, rep2, rep1 = rep2, rep1, offset
			else
				offset = rep1 - 1
				rep3, rep2, rep1 = rep2, rep1, offset
			end
			if offset <= 0 then
				fail("invalid repeat offset (corrupt block)")
			end
		end

		-- literals
		if litLenV > 0 then
			if litPos + litLenV > litLen then
				fail("sequence consumes more literals than available")
			end
			ensure(out, litLenV, maxOut)
			ob = out.buf
			buffer.copy(ob, out.len, lit, litPos, litLenV)
			litPos = litPos + litLenV
			out.len = out.len + litLenV
		end
		-- match
		if offset > out.len then
			fail("match offset reaches before the start of output")
		end
		ensure(out, matchLen, maxOut)
		ob = out.buf
		local dst = out.len
		local srcPos = dst - offset
		if offset >= matchLen then
			buffer.copy(ob, dst, ob, srcPos, matchLen)
		else
			for k = 0, matchLen - 1 do
				buffer.writeu8(ob, dst + k, buffer.readu8(ob, srcPos + k))
			end
		end
		out.len = dst + matchLen
	end
	if br.pos ~= 0 then
		fail("sequence bitstream not fully consumed (corrupt block)")
	end
	st.rep1, st.rep2, st.rep3 = rep1, rep2, rep3
	local remain = litLen - litPos
	if remain > 0 then
		ensure(out, remain, maxOut)
		buffer.copy(out.buf, out.len, lit, litPos, remain)
		out.len = out.len + remain
	end
end

-------------------------------------------------------------------------------
-- Frames
-------------------------------------------------------------------------------
local function decompress(data, maxOutput)
	maxOutput = maxOutput or DEFAULT_MAX_OUTPUT
	local n = #data
	local p = 1
	local out
	local frames = 0
	while p <= n do
		local m0, m1, m2, m3 = byte(data, p, p + 3)
		if m3 == nil then
			fail("truncated frame magic")
		end
		local magic = m0 + m1 * 256 + m2 * 65536 + m3 * 16777216
		if magic >= 0x184D2A50 and magic <= 0x184D2A5F then
			local z0, z1, z2, z3 = byte(data, p + 4, p + 7)
			if z3 == nil then
				fail("truncated skippable frame")
			end
			local sz = z0 + z1 * 256 + z2 * 65536 + z3 * 16777216
			p = p + 8 + sz
			continue
		end
		if magic ~= 0xFD2FB528 then
			fail("not a Zstandard frame (bad magic at byte " .. p .. ")")
		end
		p = p + 4
		local fhd = byte(data, p)
		if fhd == nil then
			fail("truncated frame header")
		end
		p = p + 1
		local fcsFlag = fhd // 64
		local single = (fhd // 32) % 2 == 1
		local hasChecksum = (fhd // 4) % 2 == 1
		local dictFlag = fhd % 4
		if (fhd // 8) % 2 == 1 then
			fail("reserved bit set in frame header")
		end
		if not single then
			p = p + 1 -- window descriptor
		end
		local dictBytes = ({ [0] = 0, 1, 2, 4 })[dictFlag]
		local dictId = 0
		for i = 0, dictBytes - 1 do
			dictId = dictId + (byte(data, p + i) or 0) * POW2[8 * i]
		end
		p = p + dictBytes
		if dictId ~= 0 then
			fail("frame requires dictionary " .. dictId .. " (dictionaries are not supported)")
		end
		local fcsBytes = ({ [0] = single and 1 or 0, 2, 4, 8 })[fcsFlag]
		local contentSize
		if fcsBytes > 0 then
			contentSize = 0
			for i = 0, fcsBytes - 1 do
				contentSize = contentSize + (byte(data, p + i) or 0) * POW2[8 * i]
			end
			if fcsBytes == 2 then
				contentSize = contentSize + 256
			end
			p = p + fcsBytes
		end
		if contentSize and contentSize > maxOutput then
			fail("frame declares " .. contentSize .. " bytes, above the allowed maximum")
		end
		if out == nil then
			out = newOut(contentSize and math.min(contentSize, maxOutput) or 65536)
		end
		local frameStart = out.len
		local st = { rep1 = 1, rep2 = 4, rep3 = 8 }
		while true do
			local h0, h1, h2 = byte(data, p, p + 2)
			if h2 == nil then
				fail("truncated block header")
			end
			local h = h0 + h1 * 256 + h2 * 65536
			local last = h % 2 == 1
			local btype = (h // 2) % 4
			local bsize = h // 8
			p = p + 3
			if btype == 0 then
				if p + bsize - 1 > n then
					fail("raw block runs past end of data")
				end
				ensure(out, bsize, maxOutput)
				buffer.writestring(out.buf, out.len, sub(data, p, p + bsize - 1))
				out.len = out.len + bsize
				p = p + bsize
			elseif btype == 1 then
				local v = byte(data, p)
				if v == nil then
					fail("RLE block past end of data")
				end
				ensure(out, bsize, maxOutput)
				local ob, o = out.buf, out.len
				for i = 0, bsize - 1 do
					buffer.writeu8(ob, o + i, v)
				end
				out.len = o + bsize
				p = p + 1
			elseif btype == 2 then
				if bsize > 131072 or p + bsize - 1 > n then
					fail("compressed block size invalid or past end of data")
				end
				decodeBlock(data, p, p + bsize - 1, st, out, maxOutput)
				p = p + bsize
			else
				fail("reserved block type")
			end
			if last then
				break
			end
		end
		if contentSize and out.len - frameStart ~= contentSize then
			fail("frame content size mismatch (declared " .. contentSize .. ", produced " .. (out.len - frameStart) .. ")")
		end
		if hasChecksum then
			p = p + 4 -- XXH64 low 32 bits; not verified
		end
		frames = frames + 1
	end
	if out == nil then
		return ""
	end
	return buffer.readstring(out.buf, 0, out.len)
end

function Zstd.decompress(data, maxOutput)
	if type(data) ~= "string" then
		return nil, "BreachZstd: input must be a string"
	end
	local ok, res = pcall(decompress, data, maxOutput)
	if ok then
		return res
	end
	return nil, tostring(res)
end

return Zstd
