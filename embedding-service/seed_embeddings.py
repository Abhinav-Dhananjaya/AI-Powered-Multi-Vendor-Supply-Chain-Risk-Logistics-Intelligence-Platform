"""embedding-service/seed_embeddings.py — fill risk_documents.embedding where NULL.

Usage:  DATABASE_URL=postgresql://... python seed_embeddings.py
"""
import os

import psycopg2
from sentence_transformers import SentenceTransformer

model = SentenceTransformer("sentence-transformers/all-MiniLM-L6-v2")
conn = psycopg2.connect(os.environ["DATABASE_URL"])

with conn, conn.cursor() as cur:
    cur.execute("SELECT doc_id, title, content FROM risk_documents WHERE embedding IS NULL")
    rows = cur.fetchall()
    if rows:
        texts = [f"{title}. {content}" for _, title, content in rows]
        vecs = model.encode(texts, normalize_embeddings=True, batch_size=32)
        for (doc_id, _, _), vec in zip(rows, vecs):
            cur.execute(
                "UPDATE risk_documents SET embedding = %s::vector WHERE doc_id = %s",
                ("[" + ",".join(f"{x:.7f}" for x in vec) + "]", doc_id),
            )
    print(f"Embedded {len(rows)} documents")
conn.close()
