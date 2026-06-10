# Inicializar estructura del proyecto

Crea la estructura de carpetas del EA. Ejecutar solo una vez.

## Pasos

1. Crear carpetas:
```bash
mkdir -p MQL5/Experts/TradingDataServer
mkdir -p MQL5/Include/TradingDataServer
mkdir -p docs
mkdir -p tests
```

2. Crear `tests/requirements.txt`:
```
pytest==8.2.0
```

3. Crear `.gitignore`:
```
*.ex5
*.log
__pycache__/
.pytest_cache/
```

4. Reportar estructura creada y confirmar que todo está listo
   para comenzar con `/build-ea logger`
