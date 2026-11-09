class_name CrawlBehavior
extends StatusBehavior
## Holds on to walls and ceilings: floors, walls and ceilings are all one
## surface to its routes (see Unit.can_crawl).


func grants_crawl() -> bool:
	return true


func describe() -> String:
	return "Walks on walls and ceilings. Switched off, it lets go"
