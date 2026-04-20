# 🚀 Termux Move Large → SD

**Освободи место в Termux за минуты, а не часы.**  
Интерактивный скрипт для перемещения крупных файлов на SD-карту с автоматическим созданием симлинков.

<img width="635" height="227" alt="image" src="https://github.com/user-attachments/assets/710646c0-2c7a-420d-b610-45d606ae58e4" />

---
<img width="1198" height="607" alt="image" src="https://github.com/user-attachments/assets/c2f00f08-d040-40a6-81ac-18bd11a0d308" />

## ⚡ Особенности

| Функция | Описание |
|---------|----------|
| 🎯 **Интерактивный поиск** | Живое обновление Топ-5 крупнейших файлов в реальном времени |
| ⌨️ **Пробел = старт** | [TODO] Нажми ПРОБЕЛ в любой момент — обработка найденного начнётся немедленно |
| 🔒 **FAT-safe** | Автоматическая адаптация имён файлов под ограничения FAT/exFAT |
| 🛡️ **Защита исполняемых** | Пропуск exeсutable  по умолчанию (FAT не поддерживает биты выполнения) |
| 🚄 **bfs ускорение** | До 10× быстрее стандартного `find` (автодетект + тест работоспособности) |
| ✅ **Проверка целостности** | rsync / md5 / быстрая блочная верификация на выбор |
| 📋 **Журнал операций** | Полная карта перемещений + соответствия имён для обратного восстановления |

---

## 📦 Установка

```bash
# 1. Клонируйте репозиторий
git clone https://github.com/korziner/termux_move_large2sd
cd termux-move-large-sd

# 2. Дайте права на выполнение
chmod +x termux_move_large2sd.sh

# 3. Настройте доступ к хранилищу (обязательно для Android 11+)
termux-setup-storage

# 4. Установите опциональные зависимости для скорости
pkg install rsync

wget https://archive.ubuntu.com/ubuntu/pool/universe/b/bfs/bfs_4.1.orig.tar.gz
tar xfv bfs_4.1.orig.tar.gz; cd *4.1*
CFLAGS="-mfpu=neon -O3 -Wno-implicit-function-declaration -D_GNU_SOURCE" ./configure 
make -j7; make installe 
```

```
Опции:
  -s, --source DIR        Исходный каталог (по умолч.: $HOME)
  -t, --target DIR        Целевой каталог на SD (автодетект)
  -m, --min-size SIZE     Мин. размер: K, M, G (по умолч.: 100M)
  -x, --max-size SIZE     Макс. размер (по умолч.: 4G)
  -n, --top N             Кол-во файлов для обработки (по умолч.: 20)
  -l, --link-type TYPE    absolute / relative симлинки
  --skip-cache            Исключить каталоги .cache
  --allow-executables     Разрешить перемещение исполняемых файлов
  --dry-run               Пробный запуск (без копирования)
  --debug                 Отладочный вывод (команды + детали)
  --verbose               Подробный вывод процесса
  -h, --help              Справка  
```

📊 Пример вывода
```
[INFO] 🚀 Запуск: --min-size 100M --top 40
[INFO] 📁 Источник: /data/data/com.termux/files/home
[INFO] 💾 Цель: /storage/B07A-2DD6
[INFO] ✅ bfs работоспособен — будет использоваться
[INFO] 📊 Найдено исполняемых файлов: 127
[WARN] ⚠️ Исполняемые файлы будут пропущены (FAT не поддерживает +x)
[INFO] 📊 Свободно: 26.8G
[INFO] 🔄 rsync + проверка
[INFO] 🔎 Запуск интерактивного поиска...

🔍 Поиск файлов...
=========================================
  2.6G       /home/arch-fs/root/.ollama/models/blobs/sha256-...
  2.4G       /home/arch-fs/root/2GB.img
  400.3M     /home/.cache/pip/http-v2/4/9/6/b/2/...
  214.2M     /home/.cache/huggingface/hub/models--csukuangfj--...
  198.7M     /home/.cache/huggingface/hub/datasets--burtenshaw--...
=========================================
Найдено: 494424 файлов | Лимит: 40

[ПРОБЕЛ] Копировать ЭТИ 40 (не ждать окончания)
[Ctrl+C] Полная остановка
```
Версия 2 добавляет раннюю остановку пробелом:
<img width="769" height="646" alt="image" src="https://github.com/user-attachments/assets/61da9dd4-f22d-4466-b289-329b2c26c870" />

