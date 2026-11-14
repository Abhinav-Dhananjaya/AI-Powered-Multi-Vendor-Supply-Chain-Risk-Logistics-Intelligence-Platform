"""embedding-service/main.py — FastAPI microservice producing 384-d MiniLM embeddings."""
import os
import secrets
from contextlib import asynccontextmanager
from typing import List

from fastapi import Depends, FastAPI, Header, HTTPException
from pydantic import BaseModel, Field
from sentence_transformers import SentenceTransformer

MODEL_NAME = "sentence-transformers/all-MiniLM-L6-v2"
API_KEY = os.getenv("EMBEDDING_API_KEY", "")

state: dict = {}


@asynccontextmanager
async def lifespan(_: FastAPI):
    state["model"] = SentenceTransformer(MODEL_NAME)  # loaded once at startup
    yield
    state.clear()


app = FastAPI(title="Embedding Service", version="1.0.0", lifespan=lifespan)


def check_key(x_api_key: str = Header(default="")):
    # If a key is configured, require it (constant-time compare)
    if API_KEY and not secrets.compare_digest(x_api_key, API_KEY):
        raise HTTPException(status_code=401, detail="Invalid API key")


class EmbedRequest(BaseModel):
    text: str = Field(min_length=1, max_length=8000)


class EmbedBatchRequest(BaseModel):
    texts: List[str] = Field(min_length=1, max_length=128)


@app.get("/health")
def health():
    return {"status": "ok", "model": MODEL_NAME, "dimensions": 384}


@app.post("/embed", dependencies=[Depends(check_key)])
def embed(req: EmbedRequest):
    # normalize_embeddings=True -> unit vectors, so cosine distance is well-behaved
    vec = state["model"].encode(req.text, normalize_embeddings=True)
    return {"embedding": vec.tolist(), "dimensions": len(vec)}


@app.post("/embed-batch", dependencies=[Depends(check_key)])
def embed_batch(req: EmbedBatchRequest):
    vecs = state["model"].encode(req.texts, normalize_embeddings=True, batch_size=32)
    return {"embeddings": [v.tolist() for v in vecs], "dimensions": 384}
