const express = require('express');
const cors = require('cors');
const path = require('path');

const app = express();
const PORT = process.env.PORT || 3000;

// Middleware
app.use(cors());
app.use(express.json());
app.use(express.static('public'));

// In-memory storage for tasks
let tasks = [
  { id: 1, title: 'Sample Task 1', completed: false },
  { id: 2, title: 'Sample Task 2', completed: true }
];
let nextId = 3;

// API Routes

// Get all tasks
app.get('/api/tasks', (req, res) => {
  res.json(tasks);
});

// Create new task
app.post('/api/tasks', (req, res) => {
  const { title } = req.body;
  
  if (!title) {
    return res.status(400).json({ error: 'Title is required' });
  }
  
  const newTask = {
    id: nextId++,
    title,
    completed: false
  };
  
  tasks.push(newTask);
  res.status(201).json(newTask);
});

// Update task
app.put('/api/tasks/:id', (req, res) => {
  const id = parseInt(req.params.id);
  const { title, completed } = req.body;
  
  const task = tasks.find(t => t.id === id);
  
  if (!task) {
    return res.status(404).json({ error: 'Task not found' });
  }
  
  if (title !== undefined) task.title = title;
  if (completed !== undefined) task.completed = completed;
  
  res.json(task);
});

// Delete task
app.delete('/api/tasks/:id', (req, res) => {
  const id = parseInt(req.params.id);
  const index = tasks.findIndex(t => t.id === id);
  
  if (index === -1) {
    return res.status(404).json({ error: 'Task not found' });
  }
  
  tasks.splice(index, 1);
  res.json({ message: 'Task deleted' });
});

// Health check endpoint
app.get('/api/health', (req, res) => {
  res.json({ status: 'ok', message: 'Server is running' });
});

// Serve frontend
// app.get('*', (req, res) => {
//   res.sendFile(path.join(__dirname, 'public', 'index.html'));
// });

// Start server
app.listen(PORT, '0.0.0.0', () => {
  console.log(`Server running on port ${PORT}`);
  console.log(`Open http://localhost:${PORT} in your browser`);
});