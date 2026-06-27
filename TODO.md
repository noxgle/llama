# TODO.md

## [TEST DEV] CACHE_RAM, CACHE_REUSE, CTX_CHECKPOINTS

- [ ] dodać `CACHE_RAM=4096` do wszystkich configów
- [ ] dodać `CACHE_REUSE=256` do wszystkich configów
- [ ] zmienić `CTX_CHECKPOINTS` z 4 na 8 we wszystkich configach
- [ ] dodać flagi `--cram` i `--cache-reuse` do docker-compose.yml
- [ ] dodać flagi `--cram` i `--cache-reuse` do llama.sh
- [ ] przetestować na dev (.38)
- [ ] wdrożyć na production (.19, .20, .21)
