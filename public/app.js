// API Base URL
const API_URL = 'http://13.246.198.173/:3000/api';

// Load tasks when page loads
document.addEventListener('DOMContentLoaded', () => {
    loadTasks();
    checkServerHealth();
    
    // Add task on Enter key
    document.getElementById('taskInput').addEventListener('keypress', (e) => {
        if (e.key === 'Enter') {
            addTask();
        }
    });
});

// Check server health
async function checkServerHealth() {
    try {
        const response = await fetch(`${API_URL}/health`);
        const data = await response.json();
        
        const statusElement = document.getElementById('serverStatus');
        if (data.status === 'ok') {
            statusElement.textContent = '🟢 Server Online';
            statusElement.className = 'status-online';
        }
    } catch (error) {
        const statusElement = document.getElementById('serverStatus');
        statusElement.textContent = '🔴 Server Offline';
        statusElement.className = 'status-offline';
    }
}

// Load all tasks
async function loadTasks() {
    try {
        const response = await fetch(`${API_URL}/tasks`);
        const tasks = await response.json();
        
        renderTasks(tasks);
        updateStats(tasks);
    } catch (error) {
        console.error('Error loading tasks:', error);
        showError('Failed to load tasks');
    }
}

// Render tasks to DOM
function renderTasks(tasks) {
    const tasksList = document.getElementById('tasksList');
    const emptyState = document.getElementById('emptyState');
    
    if (tasks.length === 0) {
        tasksList.innerHTML = '';
        emptyState.classList.add('show');
        return;
    }
    
    emptyState.classList.remove('show');
    
    tasksList.innerHTML = tasks.map(task => `
        <div class="task-item ${task.completed ? 'completed' : ''}">
            <input 
                type="checkbox" 
                class="task-checkbox" 
                ${task.completed ? 'checked' : ''}
                onchange="toggleTask(${task.id})"
            >
            <span class="task-text">${escapeHtml(task.title)}</span>
            <button class="delete-btn" onclick="deleteTask(${task.id})">Delete</button>
        </div>
    `).join('');
}

// Update statistics
function updateStats(tasks) {
    const total = tasks.length;
    const completed = tasks.filter(t => t.completed).length;
    const pending = total - completed;
    
    document.getElementById('totalTasks').textContent = total;
    document.getElementById('completedTasks').textContent = completed;
    document.getElementById('pendingTasks').textContent = pending;
}

// Add new task
async function addTask() {
    const input = document.getElementById('taskInput');
    const title = input.value.trim();
    
    if (!title) {
        showError('Please enter a task');
        return;
    }
    
    try {
        const response = await fetch(`${API_URL}/tasks`, {
            method: 'POST',
            headers: {
                'Content-Type': 'application/json'
            },
            body: JSON.stringify({ title })
        });
        
        if (response.ok) {
            input.value = '';
            loadTasks();
        } else {
            showError('Failed to add task');
        }
    } catch (error) {
        console.error('Error adding task:', error);
        showError('Failed to add task');
    }
}

// Toggle task completion
async function toggleTask(id) {
    try {
        const response = await fetch(`${API_URL}/tasks`);
        const tasks = await response.json();
        const task = tasks.find(t => t.id === id);
        
        await fetch(`${API_URL}/tasks/${id}`, {
            method: 'PUT',
            headers: {
                'Content-Type': 'application/json'
            },
            body: JSON.stringify({ completed: !task.completed })
        });
        
        loadTasks();
    } catch (error) {
        console.error('Error toggling task:', error);
        showError('Failed to update task');
    }
}

// Delete task
async function deleteTask(id) {
    if (!confirm('Are you sure you want to delete this task?')) {
        return;
    }
    
    try {
        const response = await fetch(`${API_URL}/tasks/${id}`, {
            method: 'DELETE'
        });
        
        if (response.ok) {
            loadTasks();
        } else {
            showError('Failed to delete task');
        }
    } catch (error) {
        console.error('Error deleting task:', error);
        showError('Failed to delete task');
    }
}

// Utility functions
function escapeHtml(text) {
    const div = document.createElement('div');
    div.textContent = text;
    return div.innerHTML;
}

function showError(message) {
    alert(message);
}