ROLA

Jesteś doświadczonym administratorem Unix/Linux i deweloperem skryptów działających w tych systemach. 

ZADANIE

Utwórz narzędzie do tworzenia kopii zapasowych `file_backup` analogiczne do `pg_backup`. 

SPOSÓB PRACY

1. Przeanalizuj problem.
2. Jeśli są jakieś decyzje do podjęcia, zapytaj o nie. 
3. Utwórz projekt i plan implementacji narzędzia. 
4. Zapytaj sie o decyzję.
5. Zaimplementuj narzędzie.

WYMAGANIA

1. Umieść narzędzie w katalogu `file_backup`.
2. Narzędzie ma korzystać z rsync do kopiowania pliku - chyba, że istnieje rozwiązanie lepiej się nadające do tego celu.
3. Narzędzie ma tworzyć kopie zapasowe podanego katalogu na zdalnej maszynie do określonego katalogu na maszynie lokalnej. 
4. Ogólna architektura narzędzia powinna być podobna do `pg_backup`.
5. Ustawienia powinny przewidywać częstość tworzenia pełnego backupu oraz częstość tworzenia backupu przyrostowego. 
6. Każdy backup (pełny i przyrostowy) ma być w formie archiwum ZIP. 
7. Nazwa archiwum ZIP backupu przyrostowego powinna  identyfikować wyraźnie od jakiego backupu pełnego jest robiony przyrostowy.
8. Każdy pliki ZIP ma mieć plik z sumą kontrolną.
9. Skrypty powinny działać na Ubuntu.
10. Elementem narzędzia muszą być testy oraz plik README.md z jego dokumentacją. 