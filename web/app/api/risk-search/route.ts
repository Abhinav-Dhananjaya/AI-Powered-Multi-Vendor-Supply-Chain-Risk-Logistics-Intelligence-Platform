// app/api/risk-search/route.ts — semantic search: FastAPI embeds the query, pgvector ranks documents
import { NextRequest, NextResponse } from "next/server";
import { pool } from "@/lib/db";
import { getSessionFromRequest, can } from "@/lib/auth";

export async function POST(req: NextRequest) {
  const session = await getSessionFromRequest(req);
  if (!session) return NextResponse.json({ error: "Unauthenticated" }, { status: 401 });
  if (!can(session, "risk:search")) return NextResponse.json({ error: "Forbidden" }, { status: 403 });

  const { query, limit = 5, docType } = await req.json().catch(() => ({}));
  if (typeof query !== "string" || query.trim().length < 3 || query.length > 1000) {
    return NextResponse.json({ error: "query must be 3-1000 characters" }, { status: 400 });
  }
  const k = Math.min(Math.max(Number(limit) || 5, 1), 20);
  if (docType && !["Contract", "News"].includes(docType)) {
    return NextResponse.json({ error: "docType must be Contract or News" }, { status: 400 });
  }

  // 1) Embed the query via the Python microservice (384-d, L2-normalised)
  let embedding: number[];
  try {
    const r = await fetch(`${process.env.EMBEDDING_SERVICE_URL}/embed`, {
      method: "POST",
      headers: { "Content-Type": "application/json", "x-api-key": process.env.EMBEDDING_API_KEY ?? "" },
      body: JSON.stringify({ text: query }),
      signal: AbortSignal.timeout(10_000),
      cache: "no-store",
    });
    if (!r.ok) throw new Error(`embedding service ${r.status}`);
    embedding = (await r.json()).embedding;
    if (!Array.isArray(embedding) || embedding.length !== 384) throw new Error("bad embedding shape");
  } catch (e) {
    console.error(e);
    return NextResponse.json({ error: "Embedding service unavailable" }, { status: 502 });
  }

  // 2) Cosine-distance search (HNSW index). Vector is sent as a parameter, never string-concatenated into SQL.
  const vectorLiteral = `[${embedding.join(",")}]`;
  const { rows } = await pool.query(
    `SELECT d.doc_id, d.doc_type, d.title, s.name AS supplier,
            1 - (d.embedding <=> $1::vector) AS similarity,
            left(d.content, 240) AS snippet, d.published_at
       FROM risk_documents d
       LEFT JOIN suppliers s ON s.supplier_id = d.supplier_id
      WHERE d.embedding IS NOT NULL
        AND ($3::text IS NULL OR d.doc_type = $3)
      ORDER BY d.embedding <=> $1::vector
      LIMIT $2`,
    [vectorLiteral, k, docType ?? null]
  );
  return NextResponse.json({ results: rows });
}
