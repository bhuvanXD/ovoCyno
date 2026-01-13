Map<Id, Account> m = new Map<Id, Account>();
Account a = new Account(Name='Test');
insert a;
m.put(a.Id, a);

List<Account> values = m.values();
System.debug('Is values list empty? ' + values.isEmpty());

try {
    values.add(new Account(Name='Test2'));
    System.debug('Added to values list successfully.');
} catch (Exception e) {
    System.debug('Error adding to values list: ' + e.getMessage());
}
