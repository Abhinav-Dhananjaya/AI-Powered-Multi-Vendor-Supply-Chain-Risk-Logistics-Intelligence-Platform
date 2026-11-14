// lib/mongo.ts — MongoDB Atlas client (singleton)
import { MongoClient, Db } from "mongodb";

declare global {
  // eslint-disable-next-line no-var
  var __mongoClient: Promise<MongoClient> | undefined;
}

if (!process.env.MONGODB_URI) {
  throw new Error("MONGODB_URI is not set");
}

const clientPromise: Promise<MongoClient> =
  global.__mongoClient ?? new MongoClient(process.env.MONGODB_URI).connect();

if (process.env.NODE_ENV !== "production") global.__mongoClient = clientPromise;

export async function getMongoDb(): Promise<Db> {
  const client = await clientPromise;
  return client.db(process.env.MONGODB_DB ?? "scm_telemetry");
}
