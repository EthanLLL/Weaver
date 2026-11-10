import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import './fonts.css'
import './index.css'
import './theme'
import App from './App.tsx'
import { Signup } from './Signup'
import { registerWorker } from './push'
import { fitToKeyboard } from './viewport'

fitToKeyboard()
registerWorker()

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    {location.hostname.startsWith('weaver.') ? <Signup /> : <App />}
  </StrictMode>,
)
