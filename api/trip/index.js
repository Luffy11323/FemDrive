// api/trip/index.js
import { promises as fs } from "fs";
import path from "path";

export const config = { api: { bodyParser: false } };

export default async function handler(req, res) {
  if (req.method !== "GET") return res.status(405).end();

  try {
    const filePath = path.join(process.cwd(), "static", "trip.html");
    const html = await fs.readFile(filePath, "utf8");

    res.setHeader("Content-Type", "text/html");
    res.status(200).send(html);
  } catch (err) {
    console.error(err);
    res.status(500).send("Server error – trip.html not found");
  }
}