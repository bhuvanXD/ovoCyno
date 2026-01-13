//This batch class deletes Job__c records which takes up a lot of space
// to run this: Database.executeBatch(new BatchDeleteJobs(), 2000);
global class BatchDeleteJobs implements Database.Batchable<sObject> {

    global Database.QueryLocator start(Database.BatchableContext BC) {
        // REPLACE 'Job__c' with the actual API Name of your object
        return Database.getQueryLocator('SELECT Id FROM Job__c');
    }

    global void execute(Database.BatchableContext BC, List<sObject> scope) {
        // 1. Delete the records (Soft Delete)
        delete scope;

        // 2. Permanently delete from Recycle Bin to free storage immediately (Hard Delete)
        Database.emptyRecycleBin(scope);
    }

    global void finish(Database.BatchableContext BC) {
        System.debug('Batch Deletion Complete. Storage should be reclaimed.');
    }
}
//----------------------------------------------------------------//
/*
Script for deleting developer console logs:

// Fetches 100 logs and deletes them via Tooling API HTTP request
List<ApexLog> logs = [SELECT Id FROM ApexLog LIMIT 100];

for (ApexLog log : logs) {
    HttpRequest req = new HttpRequest();
    req.setHeader('Authorization', 'Bearer ' + UserInfo.getSessionId());
    req.setEndpoint(
        Url.getOrgDomainUrl().toExternalForm() +
        '/services/data/v60.0/tooling/sobjects/ApexLog/' +
        log.Id
    );
    req.setMethod('DELETE');

    Http h = new Http();
    HttpResponse res = h.send(req);
}

System.debug('Deleted batch of ' + logs.size() + ' logs.');
*/