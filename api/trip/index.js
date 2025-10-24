// api/trip/index.js
import { promises as fs } from 'fs';
import path from 'path';

export default async function handler(req, res) {
  if (req.method !== 'GET') {
    return res.status(405).json({ error: 'Method not allowed' });
  }

  const shareId = req.query.shareId || 'unknown';

  try {
    // CORRECT PATH: static/trip.html
    const filePath = path.join(process.cwd(), 'static', 'trip.html');
    
    const html = await fs.readFile(filePath, 'utf8');
    
    res.setHeader('Content-Type', 'text/html');
    res.status(200).send(html);
    
    console.log(`Served static/trip.html for shareId: ${shareId}`);
  } catch (error) {
    console.error('Error serving static/trip.html:', error);
    res.status(500).send('Server error: trip.html not found');
  }
}